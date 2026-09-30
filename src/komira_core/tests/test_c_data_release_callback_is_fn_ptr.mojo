# =============================================================================
# FALSIFIER: the Arrow C Data Interface `release` slot must hold a real
#            function pointer, not a heap byte.
# =============================================================================
#
# BUG CLASS — remote code jump / SIGBUS in any conforming consumer.
#
# The Arrow C Data Interface spec declares, verbatim:
#
#     struct ArrowSchema { ...; void (*release)(struct ArrowSchema*); ... };
#     struct ArrowArray  { ...; void (*release)(struct ArrowArray*);  ... };
#     struct ArrowArrayStream { ...; void (*release)(struct ArrowArrayStream*); ... };
#
# and mandates that the CONSUMER calls that slot exactly once, after which the
# callee must have set `release = NULL` ("released structure" contract). Arrow's
# own C helpers `abort()` when a release callback fails to null itself out.
#
# A slot that holds a live-marker — a pointer to a ONE-BYTE HEAP ALLOCATION
# holding the value 1 — instead of a function is non-NULL, so `is_released()`
# reports False and every Mojo-side test passes; but any consumer that does
# what the ABI says — call it — jumps the program counter into an allocator
# data byte. The install sites are the array / schema / stream release
# setters in `arrow/c_data_stream.mojo` and `arrow/c_data_interface.mojo`.
#
# THE FALSIFIER: every test below reaches the `release` slot through a
# `def(ptr) thin -> None` fn-ptr and CALLS it, exactly as C's
# `array.release(&array)` does. Against a heap-byte slot that transfers
# control to a heap byte and the process dies with SIGBUS (exit 138) /
# SIGSEGV — the whole test binary dies, no assertion is ever reached. With a
# real callback it runs, frees the heap this module allocated, nulls
# `release`, and the assertions below observe the spec's released state.
#
# NOTE ON STORAGE: every exported struct below lives on the HEAP and is read
# back THROUGH ITS POINTER, for the reason documented at length in
# `test_c_data_interface_release.mojo` — a stack local read after a
# by-pointer mutation lets the compiler serve a stale copy, which produces a
# TCMallocInternalCfree crash.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from std.memory import alloc

from komira_core.arrow import (
    ArrowType,
    Column,
    Field,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
    StringArray,
    CArrowSchema,
    CArrowArray,
    export_schema,
    export_primitive,
)
from komira_core.arrow.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
)
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion


# =============================================================================
# The consumer side of the ABI, spelled out.
# =============================================================================
#
# These three aliases ARE the spec's callback types. Nothing in this file calls
# a production `release_c_*` helper — the whole point is to prove the *slot*
# is a callable code pointer, independently of any Mojo-side convenience
# wrapper. A conforming C consumer has nothing else to go on.

comptime _OpaquePtr = UnsafePointer[NoneType, MutUntrackedOrigin]
comptime _CSchemaPtr = UnsafePointer[CArrowSchema, MutUntrackedOrigin]
comptime _CArrayPtr = UnsafePointer[CArrowArray, MutUntrackedOrigin]
comptime _CStreamPtr = UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]

comptime _SchemaReleaseFn = def (_CSchemaPtr) thin -> None
comptime _ArrayReleaseFn = def (_CArrayPtr) thin -> None
comptime _StreamReleaseFn = def (_CStreamPtr) thin -> None


@always_inline
def _as_schema_release_fn(p: _OpaquePtr) -> _SchemaReleaseFn:
    """Reinterpret the `release` slot as `void (*)(struct ArrowSchema*)`.

    # SAFETY: this is the CONSUMER half of the C Data Interface ABI, expressed
    # in Mojo. The slot is declared `void*` in this library's struct only
    # because the struct predates Mojo fn-ptr fields; per the spec it holds a function
    # pointer, and both are one 8-byte word, so the reinterpret is exactly what
    # a C consumer's `((void(*)(ArrowSchema*))s->release)(s)` compiles to. Test
    # -local; no raw pointer crosses back out.
    """
    return UnsafePointer(to=p).bitcast[_SchemaReleaseFn]()[]


@always_inline
def _as_array_release_fn(p: _OpaquePtr) -> _ArrayReleaseFn:
    """Reinterpret the `release` slot as `void (*)(struct ArrowArray*)`.

    # SAFETY: see `_as_schema_release_fn`.
    """
    return UnsafePointer(to=p).bitcast[_ArrayReleaseFn]()[]


@always_inline
def _as_stream_release_fn(p: _OpaquePtr) -> _StreamReleaseFn:
    """Reinterpret the `release` slot as `void (*)(struct ArrowArrayStream*)`.

    # SAFETY: see `_as_schema_release_fn`.
    """
    return UnsafePointer(to=p).bitcast[_StreamReleaseFn]()[]


# =============================================================================
# ArrowSchema
# =============================================================================


def test_schema_release_slot_is_callable_and_nulls_itself() raises:
    """Call `schema.release(&schema)` through the slot, as C does.

    A slot holding a live-marker's 1-byte heap allocation makes this call
    jump into it (SIGBUS/SIGSEGV, the binary dies here).
    """
    var field = Field("x", ArrowType.INT32, nullable=False)
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(export_schema(field))

    # Live struct per the spec.
    assert_false(sp[].is_released())
    var cb = _as_schema_release_fn(sp[].release)

    # THE CALL. This is `schema.release(&schema)`.
    cb(sp)

    # "Released structure": Arrow's own helpers abort() if this is not true.
    assert_true(sp[].is_released())
    assert_equal(Int(sp[].release), 0)
    # And it actually freed what it owns, rather than merely nulling a marker.
    assert_equal(Int(sp[].format), 0)
    assert_equal(Int(sp[].name), 0)
    sp.free()


def test_schema_release_slot_repeated_cycles() raises:
    """200 export -> call-the-slot cycles. A callback that frees the wrong
    thing (or a slot that is really a heap byte the allocator later reuses)
    corrupts tcmalloc long before this loop ends."""
    var sp = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    for _ in range(200):
        var field = Field("col", ArrowType.INT64, nullable=True)
        sp.unsafe_write(export_schema(field))
        assert_false(sp[].is_released())
        _as_schema_release_fn(sp[].release)(sp)
        assert_true(sp[].is_released())
    sp.free()


# =============================================================================
# ArrowArray
# =============================================================================


def test_array_release_slot_is_callable_and_nulls_itself() raises:
    """Call `array.release(&array)` through the slot, as C does.

    A heap-byte slot fails exactly like the schema case.
    """
    var arr = PrimitiveArray[DType.int32].allocate(16)
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    ap.unsafe_write(export_primitive[DType.int32](arr))

    assert_false(ap[].is_released())
    assert_true(Int(ap[].buffers) != 0)
    var cb = _as_array_release_fn(ap[].release)

    # THE CALL. This is `array.release(&array)`.
    cb(ap)

    assert_true(ap[].is_released())
    assert_equal(Int(ap[].release), 0)
    assert_equal(Int(ap[].buffers), 0)
    ap.free()


def test_array_release_slot_repeated_cycles() raises:
    """200 export -> call-the-slot cycles on a nullable array (exercises the
    validity slot of the buffers array)."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(16)
    arr._set_null(3)
    arr.null_count = 1
    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    for _ in range(200):
        ap.unsafe_write(export_primitive[DType.int32](arr))
        assert_false(ap[].is_released())
        _as_array_release_fn(ap[].release)(ap)
        assert_true(ap[].is_released())
    ap.free()


# =============================================================================
# ArrowArrayStream — the stream builder's install site
# =============================================================================


def _make_test_batch() raises -> RecordBatch:
    var i64 = PrimitiveArray[DType.int64].from_list(
        [Int64(10), Int64(20), Int64(30), Int64(40)]
    )
    var strs = StringArray.from_strings(
        [String("alpha"), String("beta"), String("gamma"), String("delta")]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("c", ArrowType.STRING, nullable=False))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_primitive[DType.int64](i64^))
    rbb.add_column(Column.from_string(strs^))
    return rbb.build(sb.build())


def test_stream_release_slot_is_callable_and_nulls_itself() raises:
    """Call `stream.release(&stream)` through the slot, as C does.

    `build_record_batch_stream` must install a real callback, not a
    live-marker.
    """
    var batches = Slab[RecordBatch]()
    batches.append(_make_test_batch())
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("c", ArrowType.STRING, nullable=False))

    var stp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    stp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, sb.build(), stp)

    assert_false(stp[].is_released())
    assert_true(Int(stp[].private_data) != 0)
    var cb = _as_stream_release_fn(stp[].release)

    # THE CALL. This is `stream.release(&stream)`.
    cb(stp)

    assert_true(stp[].is_released())
    assert_equal(Int(stp[].release), 0)
    # The producer-private `_CStreamState` (which owns the batches' heap) is
    # freed and the slot nulled — otherwise the batches leak.
    assert_equal(Int(stp[].private_data), 0)
    stp.free()


# =============================================================================
# The nested / struct-of-children shape: a root array whose release must
# recurse into the children it heap-allocated.
# =============================================================================


def test_stream_chunk_array_release_slot_recurses_into_children() raises:
    """Pull a chunk out of the stream via `get_next`, then call the chunk
    array's OWN release slot. The root is a struct-of-children; its callback
    must walk + free every child struct it allocated.

    A heap-byte chunk `release` would leave the children reclaimable only by
    the Mojo-side `release_c_array` helper, which no C consumer can see.
    """
    var batches = Slab[RecordBatch]()
    batches.append(_make_test_batch())
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("c", ArrowType.STRING, nullable=False))

    var stp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    stp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, sb.build(), stp)

    var ap = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    ap.unsafe_write(CArrowArray())
    var rc = stp[].get_next(stp.bitcast[NoneType](), ap)
    assert_equal(Int(rc), 0)

    assert_false(ap[].is_released())
    assert_equal(Int(ap[].n_children), 2)
    assert_true(Int(ap[].children) != 0)

    # THE CALL, on the chunk the consumer was handed.
    _as_array_release_fn(ap[].release)(ap)

    assert_true(ap[].is_released())
    assert_equal(Int(ap[].n_children), 0)
    assert_equal(Int(ap[].children), 0)
    ap.free()

    # Then release the stream itself, through its own slot.
    _as_stream_release_fn(stp[].release)(stp)
    assert_true(stp[].is_released())
    stp.free()


# =============================================================================
# The property that separates a code pointer from a heap byte, without needing
# a consumer at all.
# =============================================================================


def test_release_slot_is_a_constant_address_not_a_fresh_allocation() raises:
    """Two independent exports must carry the SAME `release` value.

    A function's address is a link-time constant, so every exported struct of
    a given kind points at the same code. A live-marker is a FRESH heap
    allocation per export, so these would differ — and, held live
    at the same time, they are guaranteed to differ, because two live
    allocations cannot share an address. This is a direct falsifier for
    "the slot holds data" that needs no consumer and cannot crash.

    Heap markers: two distinct malloc'd bytes, two distinct values.
    """
    var f1 = Field("a", ArrowType.INT32, nullable=False)
    var f2 = Field("b", ArrowType.FLOAT64, nullable=True)
    var s1 = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    var s2 = alloc[CArrowSchema](1).unsafe_origin_cast[MutUntrackedOrigin]()
    s1.unsafe_write(export_schema(f1))
    s2.unsafe_write(export_schema(f2))

    # Both live simultaneously: a per-struct heap marker CANNOT be equal here.
    assert_equal(Int(s1[].release), Int(s2[].release))

    var a1 = PrimitiveArray[DType.int32].allocate(4)
    var a2 = PrimitiveArray[DType.int32].allocate(8)
    var p1 = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    var p2 = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    p1.unsafe_write(export_primitive[DType.int32](a1))
    p2.unsafe_write(export_primitive[DType.int32](a2))
    assert_equal(Int(p1[].release), Int(p2[].release))

    # And the array callback is a DIFFERENT function from the schema callback —
    # they take different struct types and free different things.
    assert_true(Int(p1[].release) != Int(s1[].release))

    _as_schema_release_fn(s1[].release)(s1)
    _as_schema_release_fn(s2[].release)(s2)
    _as_array_release_fn(p1[].release)(p1)
    _as_array_release_fn(p2[].release)(p2)
    s1.free()
    s2.free()
    p1.free()
    p2.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
