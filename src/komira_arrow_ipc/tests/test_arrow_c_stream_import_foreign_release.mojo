# =============================================================================
# FALSIFIER: the IMPORT path must release a foreign struct through the
#            PRODUCER's own callback — never through ours.
# =============================================================================
#
# BUG CLASS — wild free / type confusion on the consumer side of the C Data
# Interface. `drain_record_batch_stream` is the ingress behind
# `komira_sdk.factories.from_arrow_c_stream` and
# `from_arrow_c_stream_typed`: a foreign producer (pyarrow, polars, arrow-rs,
# any C caller) allocates an `ArrowArrayStream`, we drain it, and we are
# obligated to dispose of it through ITS release callbacks — never through
# this library's own producer-side helpers (`release_c_array` ->
# `_release_array`, `release_c_stream` -> `_release_stream`).
#
# `_release_array` and `_release_stream` free heap by ASSUMING who allocated
# it. The worst assumption is about `private_data`:
#
#     if a.private_data:
#         var st = a.private_data.bitcast[_CArrayState]()
#         st.destroy_pointee()      # <-- runs Slab[Column[HeapRegion]]'s
#         st.free()                 #     destructor over the FOREIGN
#                                   #     producer's private struct, then
#                                   #     frees the producer's block
#
# A foreign `private_data` is the producer's, of an entirely different type. So
# `destroy_pointee` reads a `List` data pointer and length out of whatever
# pyarrow happens to store there and frees them, and `free()` then hands the
# producer's own live block back to the allocator. `_release_stream` has the
# identical shape against `_CStreamState`. (`export_primitive`'s docstring
# names the same trap on the export side: "a second differently-typed
# private_data would turn a cross-module release from a leak into a wild
# free".)
#
# WHY A FOREIGN PRODUCER. A round trip through `build_record_batch_stream`
# releases an array that really IS one of ours, whose `private_data` really
# IS a `_CArrayState`. The defect needs a producer that is not us. This file
# supplies one.
#
# WHAT THE PRODUCER HERE IS. A wrapper stream: `get_schema` / `get_next`
# delegate to an inner stream exported by this library so the BUFFERS are
# well-formed and the importer has real data to read, and then the delivered
# struct's `private_data` + `release` are replaced with this file's own —
# which is precisely and only what makes a struct "foreign". The private
# blocks are large ZEROED allocations, chosen so a wrong reinterpretation
# lands on an empty `Slab` rather than on a garbage pointer.
#
# ⚠ ZEROING IS NOT ENOUGH TO MAKE A WILD FREE SURVIVABLE. Against a consumer
# that releases a foreign struct through its own helpers, this file reaches
# NONE of the assertions below; the process dies inside the drain, with a
# fault reached from libc (the allocator) while releasing a struct we did not
# produce. That IS the wild free. The sibling guard
# `test_c_data_release_callback_is_fn_ptr.mojo` documents the same signature:
# "the whole test binary dies, no assertion is ever reached".
#
# The three tests each state a separate half of the contract:
#   test_foreign_array_release_callback_is_invoked   — the producer's ARRAY
#       release ran exactly once.
#   test_foreign_stream_release_callback_is_invoked  — the same for the STREAM.
#   test_foreign_array_private_data_is_not_freed_by_us — the producer's private
#       block is not handed back by the allocator afterwards, i.e. we did not
#       free memory we do not own. Compares addresses only; never reads through
#       a pointer that might be dangling.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from std.memory import alloc

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
comptime _StreamReleaseFn = def (_CStreamPtr) thin -> None


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer; `None` is the all-zero (NULL) bit pattern. Never dereferenced.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# =============================================================================
# The foreign producer's private block.
# =============================================================================
#
# ⚠ A RAW WORD ARRAY, NOT A STRUCT, AND THAT IS DELIBERATE. The point of the
# test is what happens when a consumer reinterprets these bytes as a type they
# are not. Declaring a Mojo struct here would make the test depend on Mojo's
# field ordering for BOTH types; a word array depends on nothing. It is sized
# far larger than `_CArrayState` (5 words) or `_CStreamState` (~7), and starts
# fully zeroed, so a wrong reinterpretation lands on an empty `Slab` /
# `List` — destructor no-op — rather than on a garbage pointer.
#
# Slot map (both blocks share it; slots 0..31 stay zero forever):
comptime _FP_WORDS = 64
comptime _FP_MAGIC_SLOT = 32
comptime _FP_CALLS_SLOT = 33
comptime _FP_INNER_PRIVATE_SLOT = 34
comptime _FP_INNER_RELEASE_SLOT = 35
comptime _FP_INNER_STREAM_SLOT = 36
comptime _FP_ARRAY_PRIV_SLOT = 37
comptime _FP_MAGIC = 0x4645_4F52_4749_4E01  # "FEORIGN\x01"


def _new_foreign_priv() -> UnsafePointer[Int, MutUntrackedOrigin]:
    """Allocate + zero one foreign private block.

    # SAFETY: FFI carve-out. This file is a C-ABI producer; the block is opaque
    # `void*` to everything but the callbacks below, exactly as a real
    # producer's private struct is.
    """
    var p = alloc[Int](_FP_WORDS).unsafe_origin_cast[MutUntrackedOrigin]()
    for i in range(_FP_WORDS):
        (p + i).unsafe_write(0)
    p[_FP_MAGIC_SLOT] = _FP_MAGIC
    return p


@always_inline
def _ptr_slots(p: UnsafePointer[Int, MutUntrackedOrigin]) -> UnsafePointer[
    _OpaquePtr, MutUntrackedOrigin
]:
    """A pointer-typed view of the same block — `Int` and `void*` are both one
    machine word, so slot indices coincide.

    # SAFETY: same allocation, same word size; used only for slots this file
    # writes as pointers and reads back as pointers.
    """
    return p.bitcast[_OpaquePtr]()


# =============================================================================
# The foreign producer's callbacks.
# =============================================================================


def _foreign_array_release(arr_ptr: _CArrayPtr) -> None:
    """`void (*release)(struct ArrowArray*)` for a delivered chunk.

    Records the call, then restores the inner state exported by this library
    and delegates to its producer-side release so the underlying export is
    genuinely reclaimed — this file leaks nothing whether or not the consumer
    behaves.
    """
    if Int(arr_ptr) == 0:
        return
    ref a = arr_ptr[]
    if a.is_released():
        return
    var fp = a.private_data.bitcast[Int]()
    fp[_FP_CALLS_SLOT] += 1
    var slots = _ptr_slots(fp)
    a.private_data = slots[_FP_INNER_PRIVATE_SLOT]
    a.release = slots[_FP_INNER_RELEASE_SLOT]
    release_c_array(arr_ptr)


def _foreign_stream_release(stream_ptr: _CStreamPtr) -> None:
    """`void (*release)(struct ArrowArrayStream*)` for the wrapper stream."""
    if Int(stream_ptr) == 0:
        return
    ref st = stream_ptr[]
    if st.is_released():
        return
    var fp = st.private_data.bitcast[Int]()
    fp[_FP_CALLS_SLOT] += 1
    var slots = _ptr_slots(fp)
    var inner = slots[_FP_INNER_STREAM_SLOT].bitcast[CArrowArrayStream]()
    if Int(inner) != 0:
        release_c_stream(inner)
    st.release = _null_ptr[NoneType, MutUntrackedOrigin]()


def _foreign_get_schema(stream: _OpaquePtr, out_schema: _CSchemaPtr) abi("C") -> Int32:
    """Delegate to the inner stream so the schema is a real, importable one."""
    var sp = stream.bitcast[CArrowArrayStream]()
    var fp = sp[].private_data.bitcast[Int]()
    var inner = _ptr_slots(fp)[_FP_INNER_STREAM_SLOT].bitcast[CArrowArrayStream]()
    return inner[].get_schema(inner.bitcast[NoneType](), out_schema)


def _foreign_get_next(stream: _OpaquePtr, out_array: _CArrayPtr) abi("C") -> Int32:
    """Delegate to the inner stream, then MAKE THE DELIVERED CHUNK FOREIGN.

    The buffers, children and lengths stay exactly as the inner export built them — the
    importer has real data to copy. Only `private_data` and `release` are
    replaced, which is the entire difference between "an array we produced" and
    "an array someone else produced".
    """
    var sp = stream.bitcast[CArrowArrayStream]()
    var wfp = sp[].private_data.bitcast[Int]()
    var wslots = _ptr_slots(wfp)
    var inner = wslots[_FP_INNER_STREAM_SLOT].bitcast[CArrowArrayStream]()
    var rc = inner[].get_next(inner.bitcast[NoneType](), out_array)
    if rc != 0:
        return rc
    if out_array[].is_released():
        return rc  # end of stream: leave the sentinel alone
    var afp = wslots[_FP_ARRAY_PRIV_SLOT].bitcast[Int]()
    var aslots = _ptr_slots(afp)
    aslots[_FP_INNER_PRIVATE_SLOT] = out_array[].private_data
    aslots[_FP_INNER_RELEASE_SLOT] = out_array[].release
    out_array[].private_data = afp.bitcast[NoneType]()
    var f: _ArrayReleaseFn = _foreign_array_release
    out_array[].release = UnsafePointer(to=f).bitcast[_OpaquePtr]()[]
    return rc


def _foreign_get_last_error(stream: _OpaquePtr) abi("C") -> UnsafePointer[Int8, MutUntrackedOrigin]:
    _ = stream
    return _null_ptr[Int8, MutUntrackedOrigin]()


# =============================================================================
# Fixture.
# =============================================================================


def _schema2() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    return sb.build()


def _batch() raises -> RecordBatch:
    var ints = PrimitiveArray[DType.int64].from_list(
        [Int64(7), Int64(8), Int64(9)]
    )
    var strs = StringArray.from_strings(
        [String("alpha"), String("beta"), String("gamma")]
    )
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](ints^))
    rbb.add_column(Column.from_string(strs^))
    return rbb.build(_schema2())


struct _Foreign(Movable):
    """The three heap blocks one foreign stream needs, kept together so the
    test can read the producers' release counters after the drain. See
    `free_all` for why only one of the three is reclaimed."""

    var stream: _CStreamPtr
    var stream_priv: UnsafePointer[Int, MutUntrackedOrigin]
    var array_priv: UnsafePointer[Int, MutUntrackedOrigin]

    def __init__(
        out self,
        stream: _CStreamPtr,
        stream_priv: UnsafePointer[Int, MutUntrackedOrigin],
        array_priv: UnsafePointer[Int, MutUntrackedOrigin],
    ):
        self.stream = stream
        self.stream_priv = stream_priv
        self.array_priv = array_priv

    def free_all(self):
        """Free only the outer stream struct.

        ⚠ THE TWO PRIVATE BLOCKS ARE DELIBERATELY LEAKED (512 bytes each). They
        are the memory whose ownership is under test: a consumer that wrongly
        frees them has already done so by the time this runs, and freeing them
        here would then abort the process on glibc's double-free check before a
        single assertion could report what actually went wrong. A leak that
        keeps the falsifier legible is worth more than a tidy teardown that
        hides it.
        """
        self.stream.free()


def _make_foreign_stream() raises -> _Foreign:
    """A foreign `ArrowArrayStream*` over one batch exported by this library.

    Heap storage throughout: `drain_record_batch_stream` documents why a stack
    `var` + `UnsafePointer(to=)` is unsound across an FFI callback.
    """
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(_batch())

    var inner = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    inner.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, _schema2(), inner)

    var spriv = _new_foreign_priv()
    var apriv = _new_foreign_priv()
    var sslots = _ptr_slots(spriv)
    sslots[_FP_INNER_STREAM_SLOT] = inner.bitcast[NoneType]()
    sslots[_FP_ARRAY_PRIV_SLOT] = apriv.bitcast[NoneType]()

    var outer = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    outer.unsafe_write(CArrowArrayStream())
    outer[].get_schema = _foreign_get_schema
    outer[].get_next = _foreign_get_next
    outer[].get_last_error = _foreign_get_last_error
    outer[].private_data = spriv.bitcast[NoneType]()
    var f: _StreamReleaseFn = _foreign_stream_release
    outer[].release = UnsafePointer(to=f).bitcast[_OpaquePtr]()[]

    return _Foreign(stream=outer, stream_priv=spriv, array_priv=apriv)


# =============================================================================
# Tests.
# =============================================================================


def test_foreign_array_release_callback_is_invoked() raises:
    """A chunk delivered by a foreign producer must be disposed of through
    ITS OWN `release`, so its `private_data` is only ever interpreted by the
    code that created it.

    A drain that calls `release_c_array` (this library's `_release_array`)
    instead bitcasts the producer's private block to `_CArrayState`, destroys
    it and frees it; this assertion then reads 0.
    """
    var fx = _make_foreign_stream()
    var batches = drain_record_batch_stream(fx.stream)

    assert_equal(len(batches), 1, "one chunk drained")
    assert_equal(batches[0].num_rows(), 3, "chunk row count survived the import")
    assert_equal(
        fx.array_priv[_FP_CALLS_SLOT],
        1,
        "the foreign producer's ARRAY release callback ran exactly once",
    )
    assert_equal(
        fx.array_priv[_FP_MAGIC_SLOT],
        _FP_MAGIC,
        "the foreign producer's private block still holds its own magic",
    )
    fx.free_all()


def test_foreign_stream_release_callback_is_invoked() raises:
    """Same claim, one level up: the STREAM's `private_data` is the producer's
    too, and `_release_stream` bitcast it to `_CStreamState`.

    A drain that runs this library's own `_release_stream` reads 0 here.
    """
    var fx = _make_foreign_stream()
    var batches = drain_record_batch_stream(fx.stream)
    _ = len(batches)

    assert_equal(
        fx.stream_priv[_FP_CALLS_SLOT],
        1,
        "the foreign producer's STREAM release callback ran exactly once",
    )
    assert_true(fx.stream[].is_released(), "released structure: release == NULL")
    assert_equal(
        fx.stream_priv[_FP_MAGIC_SLOT],
        _FP_MAGIC,
        "the foreign producer's stream private block still holds its magic",
    )
    fx.free_all()


def test_foreign_array_private_data_is_not_freed_by_us() raises:
    """The wild free, observed directly and without dereferencing anything.

    After the drain, ask the allocator for several blocks of the same size. If
    this library freed the producer's private block, that block is on the free
    list and comes back. Addresses are only COMPARED, never read through, so
    this test is sound whichever way it goes.

    A `_release_array` that does `st.free()` on the producer's block hands it
    straight back.
    """
    var fx = _make_foreign_stream()
    var batches = drain_record_batch_stream(fx.stream)
    _ = len(batches)

    var probes = List[UnsafePointer[Int, MutUntrackedOrigin]]()
    var collided = False
    for _ in range(8):
        var q = alloc[Int](_FP_WORDS).unsafe_origin_cast[MutUntrackedOrigin]()
        if q == fx.array_priv or q == fx.stream_priv:
            collided = True
        probes.append(q)
    for i in range(len(probes)):
        probes[i].free()

    assert_false(
        collided,
        "a fresh allocation reused the foreign producer's private block —"
        " this library freed memory it does not own",
    )
    fx.free_all()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
