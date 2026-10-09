# =============================================================================
# FALSIFIER: a NULL BUFFER POINTER and a NULL `release` MEAN DIFFERENT THINGS.
# =============================================================================
#
# BUG CLASS — one null test standing in for a different null test at the Arrow
# C Data Interface boundary. The import path (`drain_record_batch_stream`, the
# ingress behind `komira_sdk.factories.from_arrow_c_stream`) reads structs a
# FOREIGN producer filled in. The spec assigns THREE separate meanings to a
# NULL pointer in those structs, and they are not interchangeable:
#
#   ArrowArray.release == NULL
#       "A released structure is indicated by setting its release callback to
#        NULL. Before reading and interpreting a structure's data, consumers
#        SHOULD check for a NULL release callback and treat it accordingly
#        (probably by erroring out)."
#
#   ArrowArray.buffers[i] == NULL
#       "The buffer pointers MAY be null only in two situations: (1) for the
#        null bitmap buffer, if ArrowArray.null_count is 0; (2) for any buffer
#        (including variadic buffers), if the size in bytes of the
#        corresponding buffer would be 0."
#
#   ArrowArray.children == NULL
#       "MAY be NULL only if ArrowArray.n_children is 0."
#
# `_import_column` (`arrow/c_data_stream.mojo`) must apply case (2) only when
# the buffer's size WOULD have been 0. Treating an absent buffer as "skip the
# memcpy" unconditionally has two silent consequences:
#
#   * STRING/BINARY/LARGE_* (and LIST, MAP) offsets. `OwnedAlignedBuffer(n)`
#     zeroes only its SIMD tail-pad, never the requested bytes, so a
#     `set_length` on a never-written offsets buffer publishes (length+1)*4
#     bytes of UNINITIALISED HEAP as the column's offsets. A 3-row string
#     column would arrive with three offsets read out of whatever the
#     allocator last put there.
#
#   * Validity. A NULL validity slot must not yield `validity = None` when the
#     producer declared `null_count > 0`: `null_count` is copied from the
#     struct verbatim, so a producer that declares 2 nulls and omits the
#     bitmap — malformed under case (1), and rejected by arrow-cpp's own
#     ValidateArray — would produce a Column claiming `null_count == 2` with
#     no bitmap to say WHICH rows.
#
# WHY A HAND-BUILT PRODUCER. Every round trip through
# `build_record_batch_stream` never emits a NULL offsets buffer and never
# declares a null_count it has no bitmap for. These shapes need a producer
# that is not us, emitting what the spec permits a producer to emit. This file
# supplies one: a hand-built `ArrowArrayStream` whose every buffer slot is
# chosen by the test.
#
# FALSIFIERS (each fails against a consumer that skips absent buffers
# unconditionally):
#   test_null_offsets_with_nonzero_length_is_refused — the drain must raise
#       rather than return a 3-row column with uninitialised offsets.
#   test_null_validity_with_positive_null_count_is_refused — the drain must
#       raise rather than return null_count==2 with no validity bitmap.
#   test_zero_length_string_column_with_null_offsets_is_accepted — the case a
#       strict reading gets WRONG: the column is empty, so the buffer's size
#       would be 0, the producer is entitled to omit it, and we must NOT
#       refuse. The RE-EXPORTED offsets[0] handed to the next consumer must
#       read 0. It is asserted through the C ABI (build_record_batch_stream +
#       get_next) because those bytes ARE what pyarrow reads.
#
# PINS (pass either way) — each nails a null test to its current meaning, so
# a future non-nullable redefinition of `Bool(UnsafePointer)` cannot silently
# invert it:
#   test_released_array_is_end_of_stream_not_an_empty_batch
#   test_null_children_with_positive_n_children_is_refused
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow_ipc.c_data_stream import (
    CArrowArray,
    CArrowArrayStream,
    CArrowSchema,
    build_record_batch_stream,
    drain_record_batch_stream,
    release_c_array,
    release_c_stream,
)
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


comptime _OpaquePtr = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _CSchemaPtr = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _CArrayPtr = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _CStreamPtr = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]

comptime _ArrayReleaseFn = def (_CArrayPtr) thin -> None
comptime _SchemaReleaseFn = def (_CSchemaPtr) thin -> None
comptime _StreamReleaseFn = def (_CStreamPtr) thin -> None


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


@always_inline
def _is_null[T: AnyType, o: Origin](p: UnsafePointer[T, o]) -> Bool:
    """True iff `p` is the C NULL pointer. See the production helper of the
    same name in `c_data_stream.mojo` for why this is `Int(p) == 0` and not
    `Bool(p)`."""
    return Int(p) == 0


# =============================================================================
# THE SYNTHETIC PRODUCER
# =============================================================================
#
# ⚠ IT IS BUILT BY HAND, NOT BY WRAPPING ONE OF OURS. The sibling test
# `test_arrow_c_stream_import_foreign_release.mojo` wraps a stream exported by
# this library and swaps two fields, because what it tests is OWNERSHIP. What
# this file tests is BUFFER SHAPE, and our own export never produces the
# shapes at issue. So every pointer in every struct below is chosen here.
#
# All storage is heap; `drain_record_batch_stream` documents why a stack `var`
# plus `UnsafePointer(to=)` is unsound across an FFI callback.

comptime _MODE_WELL_FORMED = 0
"""3-row string column, every buffer present. The control."""

comptime _MODE_EMPTY_NULL_OFFSETS = 1
"""length 0, offsets slot NULL. LEGAL — spec case (2). Must be accepted, and
the offsets we hand onward must read back as 0, not as heap residue."""

comptime _MODE_LEN3_NULL_OFFSETS = 2
"""length 3, offsets slot NULL. MALFORMED — the buffer's size would be 16, not
0, so case (2) does not apply. Must be refused."""

comptime _MODE_NULL_VALIDITY_NC2 = 3
"""length 3, null_count 2, validity slot NULL. MALFORMED — case (1) permits a
NULL validity buffer only when null_count is 0. Must be refused."""

comptime _MODE_NULL_CHILDREN = 4
"""root n_children 1, children slot NULL. MALFORMED — `children` MAY be NULL
only if n_children is 0. Must be refused (already was; this pins it)."""

# Private-block slot map. A raw word array rather than a struct for the same
# reason the sibling file gives: the producer's private data is opaque bytes to
# everyone but its own callbacks, and a word array depends on no field order.
comptime _P_WORDS = 32
comptime _P_MODE = 0
comptime _P_LENGTH = 1
comptime _P_NULL_COUNT = 2
comptime _P_DELIVERED = 3
comptime _P_SCH_ROOT = 8
comptime _P_SCH_CHILD = 9
comptime _P_SCH_KIDS = 10
comptime _P_ARR_CHILD = 11
comptime _P_ARR_KIDS = 12
comptime _P_ROOT_BUFS = 13
comptime _P_CHILD_BUFS = 14
comptime _P_OFFSETS = 15
comptime _P_DATA = 16
comptime _P_VALIDITY = 17


@always_inline
def _slots(p: UnsafePointer[Int, MutUntrackedOrigin]) -> UnsafePointer[
    _OpaquePtr, MutUntrackedOrigin
]:
    """A pointer-typed view of the same block — `Int` and `void*` are both one
    machine word, so slot indices coincide.

    # SAFETY: same allocation, same word size; only slots this file writes as
    # pointers are read back as pointers.
    """
    return p.bitcast[_OpaquePtr]()


# --- release callbacks (the producer half; NULL out `release`, per spec) -----


def _p_release_array(arr_ptr: _CArrayPtr) -> None:
    """`void (*release)(struct ArrowArray*)`.

    Frees nothing: every block this producer allocated is owned by the fixture
    and reclaimed by `_Fixture.free_all` after the assertions have run. What it
    MUST do is the "released structure" half of the contract — null its own
    `release` member — because that is the bit the consumer reads back.
    """
    if _is_null(arr_ptr):
        return
    ref a = arr_ptr[]
    if a.is_released():
        return
    a.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _p_release_schema(sch_ptr: _CSchemaPtr) -> None:
    """`void (*release)(struct ArrowSchema*)`. See `_p_release_array`."""
    if _is_null(sch_ptr):
        return
    ref s = sch_ptr[]
    if _is_null(s.release):
        return
    s.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _p_release_stream(stream_ptr: _CStreamPtr) -> None:
    """`void (*release)(struct ArrowArrayStream*)`. See `_p_release_array`."""
    if _is_null(stream_ptr):
        return
    ref st = stream_ptr[]
    if st.is_released():
        return
    st.release = _null_ptr[NoneType, MutUntrackedOrigin]()


@always_inline
def _install_array_release(mut a: CArrowArray):
    var f: _ArrayReleaseFn = _p_release_array
    a.release = UnsafePointer(to=f).bitcast[_OpaquePtr]()[]


@always_inline
def _install_schema_release(mut s: CArrowSchema):
    var f: _SchemaReleaseFn = _p_release_schema
    s.release = UnsafePointer(to=f).bitcast[_OpaquePtr]()[]


# --- stream callbacks -------------------------------------------------------


def _p_get_schema(stream: _OpaquePtr, out_schema: _CSchemaPtr) abi("C") -> Int32:
    """Hand back the prebuilt root schema by value.

    The struct is copied field-by-field rather than moved so the fixture keeps
    its own copy to free; a real producer would hand over ownership.
    """
    var sp = stream.bitcast[CArrowArrayStream]()
    var fp = sp[].private_data.bitcast[Int]()
    var slots = _slots(fp)
    var src = slots[_P_SCH_ROOT].bitcast[CArrowSchema]()
    var out = CArrowSchema()
    out.format = src[].format
    out.name = src[].name
    out.metadata = src[].metadata
    out.flags = src[].flags
    out.n_children = src[].n_children
    out.children = src[].children
    out.dictionary = src[].dictionary
    _install_schema_release(out)
    out_schema.unsafe_write(out^)
    return Int32(0)


def _p_get_next(stream: _OpaquePtr, out_array: _CArrayPtr) abi("C") -> Int32:
    """Deliver exactly one chunk, then the end-of-stream sentinel.

    ⚠ THE SENTINEL IS A RELEASED STRUCT, NOT AN EMPTY ONE. Per the C Stream
    Interface, `get_next` signals exhaustion by leaving `out` in the released
    state (`release == NULL`) and returning 0 — which is precisely why
    `release == NULL` cannot also be allowed to mean "this buffer is absent".
    """
    var sp = stream.bitcast[CArrowArrayStream]()
    var fp = sp[].private_data.bitcast[Int]()
    var slots = _slots(fp)
    if fp[_P_DELIVERED] != 0:
        out_array.unsafe_write(CArrowArray())  # zeroed => release == NULL
        return Int32(0)
    fp[_P_DELIVERED] = 1

    var root = CArrowArray()
    root.length = Int64(fp[_P_LENGTH])
    root.null_count = 0
    root.offset = 0
    root.n_buffers = 1  # struct root: validity only
    root.n_children = 1
    root.buffers = slots[_P_ROOT_BUFS].bitcast[_OpaquePtr]()
    if fp[_P_MODE] == _MODE_NULL_CHILDREN:
        root.children = _null_ptr[_CArrayPtr, MutUntrackedOrigin]()
    else:
        root.children = slots[_P_ARR_KIDS].bitcast[_CArrayPtr]()
    _install_array_release(root)
    out_array.unsafe_write(root^)
    return Int32(0)


def _p_get_last_error(stream: _OpaquePtr) abi("C") -> UnsafePointer[Int8, MutUntrackedOrigin]:
    _ = stream
    return _null_ptr[Int8, MutUntrackedOrigin]()


# =============================================================================
# Fixture
# =============================================================================


struct _Fixture(Movable):
    """Every block one synthetic stream needs, so the test can free them all
    after the assertions rather than relying on a release callback that the
    behaviour under test may or may not reach."""

    var stream: _CStreamPtr
    var priv: UnsafePointer[Int, MutUntrackedOrigin]

    def __init__(out self, stream: _CStreamPtr, priv: UnsafePointer[Int, MutUntrackedOrigin]):
        self.stream = stream
        self.priv = priv

    def free_all(self):
        var slots = _slots(self.priv)
        slots[_P_SCH_ROOT].bitcast[CArrowSchema]().free()
        slots[_P_SCH_CHILD].bitcast[CArrowSchema]().free()
        slots[_P_SCH_KIDS].bitcast[_CSchemaPtr]().free()
        slots[_P_ARR_CHILD].bitcast[CArrowArray]().free()
        slots[_P_ARR_KIDS].bitcast[_CArrayPtr]().free()
        slots[_P_ROOT_BUFS].bitcast[_OpaquePtr]().free()
        slots[_P_CHILD_BUFS].bitcast[_OpaquePtr]().free()
        slots[_P_OFFSETS].bitcast[Int32]().free()
        slots[_P_DATA].bitcast[UInt8]().free()
        slots[_P_VALIDITY].bitcast[UInt8]().free()
        self.priv.free()
        self.stream.free()


def _c_string(s: String) -> UnsafePointer[Int8, MutUntrackedOrigin]:
    """Heap-allocate a null-terminated copy of `s` for a `format` / `name`
    slot. Leaked deliberately (a handful of bytes per test); freeing them would
    require tracking each one, and the memory under test is elsewhere."""
    var n = s.byte_length()
    var buf = alloc[Int8](n + 1).unsafe_origin_cast[MutUntrackedOrigin]()
    var bytes = s.as_bytes()
    for i in range(n):
        (buf + i).unsafe_write(Int8(Int(bytes[i])))
    (buf + n).unsafe_write(Int8(0))
    return buf


def _make_stream(mode: Int) raises -> _Fixture:
    """Build a one-chunk `ArrowArrayStream*` carrying a single STRING column,
    shaped by `mode`."""
    var length = 0 if mode == _MODE_EMPTY_NULL_OFFSETS else 3
    var null_count = 2 if mode == _MODE_NULL_VALIDITY_NC2 else 0

    var priv = alloc[Int](_P_WORDS).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(_P_WORDS):
        (priv + i).unsafe_write(0)
    priv[_P_MODE] = mode
    priv[_P_LENGTH] = length
    priv[_P_NULL_COUNT] = null_count
    var slots = _slots(priv)

    # --- payload blobs: offsets[0..3] over "aaabbbccc", validity 0b101 ---
    var offs = alloc[Int32](4).unsafe_origin_cast[MutUntrackedOrigin]()
    (offs + 0).unsafe_write(Int32(0))
    (offs + 1).unsafe_write(Int32(3))
    (offs + 2).unsafe_write(Int32(6))
    (offs + 3).unsafe_write(Int32(9))
    var data = alloc[UInt8](16).unsafe_origin_cast[MutUntrackedOrigin]()
    var payload = String("aaabbbccc")
    var pbytes = payload.as_bytes()
    for i in range(16):
        (data + i).unsafe_write(pbytes[i] if i < len(pbytes) else UInt8(0))
    var validity = alloc[UInt8](1).unsafe_origin_cast[MutUntrackedOrigin]()
    (validity + 0).unsafe_write(UInt8(0b101))
    slots[_P_OFFSETS] = offs.bitcast[NoneType]()
    slots[_P_DATA] = data.bitcast[NoneType]()
    slots[_P_VALIDITY] = validity.bitcast[NoneType]()

    # --- child ARRAY: the STRING column, 3 buffers ---
    var child_bufs = alloc[_OpaquePtr](3).unsafe_origin_cast[MutUntrackedOrigin]()
    # buffers[0] = validity. Present only when the mode is not testing its
    # absence; a well-formed all-valid column may legally omit it (case (1)),
    # and the control mode does exactly that with null_count == 0.
    (child_bufs + 0).unsafe_write(_null_ptr[NoneType, MutUntrackedOrigin]())
    # buffers[1] = offsets. NULL for the two offset modes.
    if mode == _MODE_EMPTY_NULL_OFFSETS or mode == _MODE_LEN3_NULL_OFFSETS:
        (child_bufs + 1).unsafe_write(_null_ptr[NoneType, MutUntrackedOrigin]())
    else:
        (child_bufs + 1).unsafe_write(offs.bitcast[NoneType]())
    # buffers[2] = utf8 bytes.
    (child_bufs + 2).unsafe_write(data.bitcast[NoneType]())
    slots[_P_CHILD_BUFS] = child_bufs.bitcast[NoneType]()

    var arr_child = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    var ac = CArrowArray()
    ac.length = Int64(length)
    ac.null_count = Int64(null_count)
    ac.offset = 0
    ac.n_buffers = 3
    ac.n_children = 0
    ac.buffers = child_bufs
    _install_array_release(ac)
    arr_child.unsafe_write(ac^)
    slots[_P_ARR_CHILD] = arr_child.bitcast[NoneType]()

    var arr_kids = alloc[_CArrayPtr](1).unsafe_origin_cast[MutUntrackedOrigin]()
    (arr_kids + 0).unsafe_write(arr_child)
    slots[_P_ARR_KIDS] = arr_kids.bitcast[NoneType]()

    var root_bufs = alloc[_OpaquePtr](1).unsafe_origin_cast[MutUntrackedOrigin]()
    (root_bufs + 0).unsafe_write(_null_ptr[NoneType, MutUntrackedOrigin]())
    slots[_P_ROOT_BUFS] = root_bufs.bitcast[NoneType]()

    # --- SCHEMA: root '+s' with one 'u' child named "s" ---
    var sch_child = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    var cs = CArrowSchema()
    cs.format = _c_string(String("u"))
    cs.name = _c_string(String("s"))
    cs.flags = 2  # ARROW_FLAG_NULLABLE
    cs.n_children = 0
    _install_schema_release(cs)
    sch_child.unsafe_write(cs^)
    slots[_P_SCH_CHILD] = sch_child.bitcast[NoneType]()

    var sch_kids = alloc[_CSchemaPtr](1).unsafe_origin_cast[MutUntrackedOrigin]()
    (sch_kids + 0).unsafe_write(sch_child)
    slots[_P_SCH_KIDS] = sch_kids.bitcast[NoneType]()

    var sch_root = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    var rs = CArrowSchema()
    rs.format = _c_string(String("+s"))
    rs.name = _c_string(String(""))
    rs.n_children = 1
    rs.children = sch_kids
    _install_schema_release(rs)
    sch_root.unsafe_write(rs^)
    slots[_P_SCH_ROOT] = sch_root.bitcast[NoneType]()

    # --- the stream itself ---
    var stream = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    stream.unsafe_write(CArrowArrayStream())
    stream[].get_schema = _p_get_schema
    stream[].get_next = _p_get_next
    stream[].get_last_error = _p_get_last_error
    stream[].private_data = priv.bitcast[NoneType]()
    var f: _StreamReleaseFn = _p_release_stream
    stream[].release = UnsafePointer(to=f).bitcast[_OpaquePtr]()[]

    return _Fixture(stream=stream, priv=priv)


def _drain_raises(mode: Int) raises -> Bool:
    """Run the drain for `mode`; report whether it refused. Never lets an
    exception escape, so the fixture is always freed."""
    var fx = _make_stream(mode)
    var raised = False
    try:
        var batches = drain_record_batch_stream(fx.stream)
        _ = len(batches)
    except e:
        _ = String(e)
        raised = True
    fx.free_all()
    return raised


# =============================================================================
# Tests
# =============================================================================


def test_null_offsets_with_nonzero_length_is_refused() raises:
    """Offsets half. A 3-row STRING column needs a 16-byte offsets buffer;
    the spec permits a NULL buffer pointer only when the buffer's size would
    be 0, so this producer is malformed and a consumer must error out rather
    than interpret it.

    A consumer that skips the absent buffer returns a 3-row column whose
    offsets buffer is uninitialised heap (`OwnedAlignedBuffer` zeroes only its
    tail-pad), so `raised` reads False. Any subsequent read of those offsets
    (concat copies offsets[0] verbatim) indexes the data buffer at an
    arbitrary value.
    """
    assert_true(
        _drain_raises(_MODE_LEN3_NULL_OFFSETS),
        "a NULL offsets buffer on a length-3 string array must be refused:"
        " Arrow C Data Interface permits a NULL buffer pointer only when the"
        " buffer's size in bytes would be 0",
    )


def test_null_validity_with_positive_null_count_is_refused() raises:
    """Validity half. `buffers[0]` may be NULL only if `null_count` is 0. A
    producer declaring 2 nulls and omitting the bitmap has said something
    self-contradictory, and arrow-cpp's own `ValidateArray` rejects it.

    A consumer that accepts it returns a Column carrying `null_count == 2`
    with `validity == None` — the two nulls exist in the count and nowhere
    else, so every row reads back as valid. `raised` is False.
    """
    assert_true(
        _drain_raises(_MODE_NULL_VALIDITY_NC2),
        "a NULL validity buffer with null_count == 2 must be refused: the"
        " Arrow C Data Interface permits it only when null_count is 0",
    )


def test_zero_length_string_column_with_null_offsets_is_accepted() raises:
    """THE CASE A STRICT READING GETS WRONG. An empty column has nothing to
    offset, the producer is entitled to omit the buffer, and refusing here
    would break real producers. So this must NOT raise — and the offsets we
    then hand to the NEXT consumer must be the canonical `[0]`, not residue.

    Asserted through the C ABI on purpose: `build_record_batch_stream` +
    `get_next` produce the exact `buffers[1]` bytes pyarrow would read.

    The no-raise half holds either way; the offsets[0] assertion is the one
    that catches a consumer that only calls `set_length(off_bytes)` on a
    buffer whose bytes were never written.
    """
    var fx = _make_stream(_MODE_EMPTY_NULL_OFFSETS)
    var batches = drain_record_batch_stream(fx.stream)

    assert_equal(len(batches), 1, "one chunk drained")
    assert_equal(batches[0].num_rows(), 0, "the chunk is empty")

    # Re-export and read offsets[0] back out of the C struct.
    var out = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    out.unsafe_write(CArrowArrayStream())
    var schema = batches[0].schema.copy()
    build_record_batch_stream(batches^, schema^, out)

    var arr = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    arr.unsafe_write(CArrowArray())
    var rc = out[].get_next(out.bitcast[NoneType](), arr)
    assert_equal(Int(rc), 0, "get_next on the re-export succeeded")
    assert_false(arr[].is_released(), "the re-exported chunk is a live struct")

    var kids = arr[].children.bitcast[_CArrayPtr]()
    var col0 = (kids + 0)[]
    var col_bufs = col0[].buffers
    var off_ptr = (col_bufs + 1)[].bitcast[Int32]()
    assert_false(_is_null(off_ptr), "the re-export supplies an offsets buffer")
    assert_equal(
        Int(off_ptr[0]),
        0,
        "offsets[0] of an empty string column must be 0 — never whatever"
        " the allocator last left in those 4 bytes",
    )

    release_c_array(arr)
    arr.free()
    release_c_stream(out)
    out.free()
    fx.free_all()


def test_released_array_is_end_of_stream_not_an_empty_batch() raises:
    """PIN (passes before and after). `release == NULL` on an ArrowArray means
    RELEASED, and `get_next` uses exactly that to signal exhaustion. It must
    stay distinguishable from a live struct whose BUFFERS happen to be NULL —
    the two are different sentences in the spec and `Bool(ptr)` conflated their
    spelling.

    The control mode delivers one live chunk (release non-NULL, 3 rows) and
    then the sentinel (release NULL). If the two were confused, the drain would
    either stop before the first chunk or spin past the sentinel.
    """
    var fx = _make_stream(_MODE_WELL_FORMED)
    var batches = drain_record_batch_stream(fx.stream)

    assert_equal(len(batches), 1, "exactly one live chunk, then the sentinel")
    assert_equal(batches[0].num_rows(), 3, "the live chunk's rows survived")
    assert_true(
        fx.stream[].is_released(),
        "released structure: the drain nulled the stream's release member",
    )
    fx.free_all()


def test_null_children_with_positive_n_children_is_refused() raises:
    """PIN (passes before and after). `children` MAY be NULL only if
    `n_children` is 0. `_import_record_batch` already refuses it; the pin
    keeps a `Bool(ptr)` redefinition from quietly dropping that check.
    """
    assert_true(
        _drain_raises(_MODE_NULL_CHILDREN),
        "a NULL children array with n_children == 1 must be refused",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
