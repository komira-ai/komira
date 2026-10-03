# =============================================================================
# test_arrow_c_stream_export_independence.mojo
#   EVERY buffer of EVERY delivered array, read AFTER the stream is released.
# =============================================================================
#
# WHAT THIS PINS. An exported chunk must own (a share of) every buffer it
# points at, so it stays readable after `release_c_stream`. The signature of a
# chunk that borrows from the stream instead is EIGHT BYTES AT OFFSET ZERO —
# the allocator's freelist link, written into the head of each freed block. A
# guard that reads only the head of only the values buffer would stay green
# against a fix that re-established ownership for `buffers[1]` and left the
# validity bitmap, the offsets buffer, the utf8 bytes, the dictionary value
# table, or a nested child still borrowing.
#
# So every test here reads EVERY buffer of EVERY array in the exported tree,
# element by element, and only after the producing stream is gone:
#
#   validity bitmap   buffers[0], bit-addressed        <- freelist link lands here
#   values            buffers[1], typed
#   offsets           buffers[1] for var-len, i32
#   utf8 bytes        buffers[2]
#   dictionary        the `.dictionary` sub-array's own 3 buffers
#   nested children   each child array's own buffers, recursively
#
# ⚠ THE READS HAPPEN THROUGH THE C STRUCT, NOT THROUGH MOJO. Going back through
# `drain_record_batch_stream` would prove nothing: the import side COPIES ("we
# do not retain pointers into foreign memory"), so a Mojo consumer cannot see
# the defect. These tests are consumers of the same kind pyarrow is — they
# hold the `void*` and dereference it — because that is the only kind that can
# observe the defect.
#
# THE ORDERING AXIS. The Arrow C data interface puts no ordering constraint on
# releases: a consumer may release the stream first, an array first, or one
# array and not its sibling. All three are exercised, because an ownership
# model that only survives one of them is not the model the spec describes.
#
# THE FAILURE THIS GUARDS: `_build_record_batch_array` pointing the chunk's
# buffer slots into the batch owned by `_CStreamState`, which
# `release_c_stream` destroys. A read of k[0] then returns a heap address
# instead of 11.
# =============================================================================

from std.memory import alloc

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.struct_array import StructArray
from komira_arrow_ipc.c_data_interface import CArrowArray
from komira_arrow_ipc.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
    release_c_array,
    release_c_stream,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion


comptime _N: Int = 4

comptime _I64_0: Int64 = 11
comptime _I64_1: Int64 = 22
comptime _I64_2: Int64 = 33
comptime _I64_3: Int64 = 44


# --- C-side readers -----------------------------------------------------------
#
# SAFETY: these read a C-ABI struct a producer just filled, exactly as a C
# consumer would — `children[i] -> buffers[j] -> bytes`. Every one of them is
# called AFTER the producing stream has been released; that is the point. The
# raw pointers never leave this file.


def _child(ref a: CArrowArray, i: Int) raises -> UnsafePointer[
    CArrowArray, MutUntrackedOrigin
]:
    """`a.children[i]`, checked."""
    assert_true(a.n_children > Int64(i), "array has child " + String(i))
    var kids = a.children.bitcast[
        UnsafePointer[CArrowArray, MutUntrackedOrigin]
    ]()
    var c = (kids + i)[]
    if Int(c) == 0:
        raise Error("child " + String(i) + " pointer is NULL")
    return c


def _buf(ref a: CArrowArray, i: Int) raises -> UnsafePointer[
    NoneType, MutUntrackedOrigin
]:
    """`a.buffers[i]`, checked non-NULL."""
    assert_true(a.n_buffers > Int64(i), "array has buffer " + String(i))
    var p = (a.buffers + i)[]
    if Int(p) == 0:
        raise Error("buffer " + String(i) + " is NULL")
    return p


def _bit_set(p: UnsafePointer[NoneType, MutUntrackedOrigin], i: Int) -> Bool:
    """Read bit `i` of a packed Arrow bitmap (validity or BOOL values)."""
    var bytes = p.bitcast[UInt8]()
    return ((bytes[i >> 3] >> UInt8(i & 7)) & UInt8(1)) == UInt8(1)


def _utf8_at(
    off_p: UnsafePointer[NoneType, MutUntrackedOrigin],
    data_p: UnsafePointer[NoneType, MutUntrackedOrigin],
    i: Int,
) -> String:
    """Rebuild element `i` of a STRING array from its i32 offsets + utf8 bytes.

    A borrowed offsets buffer fails here in pyarrow with "First or last binary
    offset out of bounds": offsets[0] holds the low half of a freed block's
    freelist link while offsets[1..3] are an untouched 1, 2, 3.
    """
    var offs = off_p.bitcast[Int32]()
    var data = data_p.bitcast[UInt8]()
    var start = Int(offs[i])
    var end = Int(offs[i + 1])
    var out = String("")
    for k in range(start, end):
        out += chr(Int(data[k]))
    return out


# --- Fixtures ----------------------------------------------------------------


def _wide_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, nullable=False))
    sb.add_field(Field("f", ArrowType.FLOAT64, nullable=False))
    sb.add_field(Field("s", ArrowType.STRING, nullable=False))
    sb.add_field(Field("b", ArrowType.BOOL, nullable=False))
    sb.add_field(Field("n", ArrowType.INT64, nullable=True))
    return sb.build()


def _nullable_i64_column() raises -> Column[HeapRegion]:
    """An INT64 column WITH a validity bitmap, so `buffers[0]` is non-NULL.

    Rows 0 and 2 valid, 1 and 3 null. The validity buffer is the one a
    values-only guard would miss.
    """
    var buf = OwnedAlignedBuffer(_N * 8)
    buf.write_i64_le_at(0, Int64(101))
    buf.write_i64_le_at(8, Int64(0))
    buf.write_i64_le_at(16, Int64(103))
    buf.write_i64_le_at(24, Int64(0))
    buf.set_length(Int64(_N * 8))
    var bm = Bitmap.create(_N)
    bm.set(0)
    bm.set(2)
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=None,
        validity=Optional[Bitmap[HeapRegion]](bm^),
        length=_N,
        null_count=2,
        offset=0,
    )


def _wide_batch() raises -> RecordBatch:
    """INT64 / FLOAT64 / STRING / BOOL / nullable-INT64 — every buffer role the
    non-nested export path can produce."""
    var i64 = PrimitiveArray[DType.int64].from_list(
        [_I64_0, _I64_1, _I64_2, _I64_3]
    )
    var f64 = PrimitiveArray[DType.float64].from_list(
        [Float64(21168.23), Float64(45983.16), Float64(13309.6), Float64(2.5)]
    )
    var strs = StringArray.from_strings(
        [String("alpha"), String("beta"), String("gamma"), String("delta")]
    )
    var bm = Bitmap.create(_N)
    bm.set(0)
    bm.set(2)
    var bools = BooleanArray.from_bitmap(bm^)

    var rbb = RecordBatchBuilder.with_capacity(5)
    rbb.add_column(Column.from_primitive[DType.int64](i64^))
    rbb.add_column(Column.from_primitive[DType.float64](f64^))
    rbb.add_column(Column.from_string(strs^))
    rbb.add_column(Column.from_boolean(bools))
    rbb.add_column(_nullable_i64_column())
    return rbb.build(_wide_schema())


def _dict_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DICTIONARY, nullable=False))
    return sb.build()


def _dict_batch() raises -> RecordBatch:
    """A DICTIONARY column: i32 codes at the parent, a STRING value table
    hanging off `.dictionary` with its OWN offsets + utf8 buffers."""
    var col = Column.from_dictionary(
        StringDictionaryArray(
            PrimitiveArray[DType.int32].from_list(
                [Int32(2), Int32(0), Int32(1), Int32(2)]
            ),
            StringArray.from_strings(
                [String("AIR"), String("RAIL"), String("SHIP")]
            ),
            _N,
        )
    )
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    return rbb.build(_dict_schema())


def _struct_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("st", ArrowType.STRUCT, nullable=False))
    return sb.build()


def _struct_batch() raises -> RecordBatch:
    """STRUCT<a: int32, b: utf8> — two child arrays, each with its own
    buffers, reached through the parent's `children` array."""
    var ints = PrimitiveArray[DType.int32].from_list(
        [Int32(7), Int32(8), Int32(9)]
    )
    var int_col = Column.from_primitive[DType.int32](ints)
    var strs = StringArray.from_strings(
        [String("one"), String("two"), String("six")]
    )
    var str_col = Column.from_string(strs^)
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var sa = StructArray.from_columns_2(names, int_col^, str_col^)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(sa.to_column())
    return rbb.build(_struct_schema())


def _export(var batch: RecordBatch, var schema: Schema) raises -> UnsafePointer[
    CArrowArrayStream, MutUntrackedOrigin
]:
    """Heap-allocate a stream over one batch. Heap, not stack: `drain_record_
    batch_stream` documents why a stack `var` + `UnsafePointer(to=)` is unsound
    across an FFI callback, and the same applies here."""
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, schema^, sp)
    return sp


def _pull(sp: UnsafePointer[CArrowArrayStream, MutUntrackedOrigin]) raises -> (
    UnsafePointer[CArrowArray, MutUntrackedOrigin]
):
    """One `get_next`, into a heap-allocated CArrowArray the caller owns."""
    var cp = alloc[CArrowArray](1).unsafe_origin_cast[MutUntrackedOrigin]()
    cp.unsafe_write(CArrowArray())
    # Same shape `drain_record_batch_stream` uses to call the callback field:
    # bind a ref, then call through it. See this module's note on why indirect
    # calls through a BITCAST fn-ptr are a different (compiler-hostile) thing.
    ref st = sp[]
    var rc = st.get_next(sp.bitcast[NoneType](), cp)
    assert_equal(Int(rc), 0, "get_next rc")
    return cp


def _assert_wide_chunk(ref chunk: CArrowArray) raises:
    """Read EVERY buffer of EVERY column of a `_wide_batch()` chunk."""
    assert_equal(Int(chunk.length), _N, "chunk row count")
    assert_equal(Int(chunk.n_children), 5, "chunk column count")

    # col 0 — INT64 values, every element.
    var c0 = _child(chunk, 0)
    var v0 = _buf(c0[], 1).bitcast[Int64]()
    assert_equal(v0[0], _I64_0, "i[0]")
    assert_equal(v0[1], _I64_1, "i[1]")
    assert_equal(v0[2], _I64_2, "i[2]")
    assert_equal(v0[3], _I64_3, "i[3]")

    # col 1 — FLOAT64 values. A borrowed buffer turns element 0 into a heap
    # pointer read as a double (~2.19e-314).
    var c1 = _child(chunk, 1)
    var v1 = _buf(c1[], 1).bitcast[Float64]()
    assert_equal(v1[0], Float64(21168.23), "f[0]")
    assert_equal(v1[1], Float64(45983.16), "f[1]")
    assert_equal(v1[2], Float64(13309.6), "f[2]")
    assert_equal(v1[3], Float64(2.5), "f[3]")

    # col 2 — STRING: offsets buffer AND utf8 buffer, both read.
    var c2 = _child(chunk, 2)
    var off2 = _buf(c2[], 1)
    var data2 = _buf(c2[], 2)
    assert_equal(Int(off2.bitcast[Int32]()[0]), 0, "offsets[0] is 0")
    assert_equal(_utf8_at(off2, data2, 0), String("alpha"), "s[0]")
    assert_equal(_utf8_at(off2, data2, 1), String("beta"), "s[1]")
    assert_equal(_utf8_at(off2, data2, 2), String("gamma"), "s[2]")
    assert_equal(_utf8_at(off2, data2, 3), String("delta"), "s[3]")

    # col 3 — BOOL packed bits (values live in buffers[1]).
    var c3 = _child(chunk, 3)
    var bits3 = _buf(c3[], 1)
    assert_true(_bit_set(bits3, 0), "b[0] true")
    assert_true(not _bit_set(bits3, 1), "b[1] false")
    assert_true(_bit_set(bits3, 2), "b[2] true")
    assert_true(not _bit_set(bits3, 3), "b[3] false")

    # col 4 — the VALIDITY bitmap at buffers[0], plus its values.
    var c4 = _child(chunk, 4)
    var val4 = _buf(c4[], 0)
    assert_true(_bit_set(val4, 0), "n[0] valid")
    assert_true(not _bit_set(val4, 1), "n[1] null")
    assert_true(_bit_set(val4, 2), "n[2] valid")
    assert_true(not _bit_set(val4, 3), "n[3] null")
    var v4 = _buf(c4[], 1).bitcast[Int64]()
    assert_equal(v4[0], Int64(101), "n[0] value")
    assert_equal(v4[2], Int64(103), "n[2] value")


# --- Tests -------------------------------------------------------------------


def test_every_buffer_survives_stream_release() raises:
    """Release the stream, THEN read every buffer of every column.

    If `release_c_stream` destroyed the `_CStreamState` that owned the batch
    the buffer pointers aim at, the first eight bytes of each buffer would
    become the allocator's freelist link.
    """
    var sp = _export(_wide_batch(), _wide_schema())
    var cp = _pull(sp)

    # Sanity: right BEFORE the release. If this fails the fixture is wrong,
    # not the ownership model.
    _assert_wide_chunk(cp[])

    release_c_stream(sp)
    assert_true(sp[].is_released(), "stream released")
    sp.free()

    # THE ASSERTION THAT MATTERS. Same reads, stream gone.
    _assert_wide_chunk(cp[])

    release_c_array(cp)
    assert_true(cp[].is_released(), "chunk released")
    cp.free()


def test_dictionary_value_table_survives_stream_release() raises:
    """A DICTIONARY array's `.dictionary` sub-array has its own release and its
    own buffers; releasing the stream must not invalidate either half.

    The same failure one level deeper: the value table's offsets + utf8 bytes
    must not come straight out of the batch's column.
    """
    var sp = _export(_dict_batch(), _dict_schema())
    var cp = _pull(sp)

    release_c_stream(sp)
    assert_true(sp[].is_released(), "stream released")
    sp.free()

    var c = _child(cp[], 0)
    # Parent: i32 dictionary codes.
    var codes = _buf(c[], 1).bitcast[Int32]()
    assert_equal(Int(codes[0]), 2, "code[0]")
    assert_equal(Int(codes[1]), 0, "code[1]")
    assert_equal(Int(codes[2]), 1, "code[2]")
    assert_equal(Int(codes[3]), 2, "code[3]")
    # Child: the STRING value table hanging off `.dictionary`.
    var dict_a = c[].dictionary
    if Int(dict_a) == 0:
        raise Error("dictionary sub-array is NULL")
    assert_equal(Int(dict_a[].length), 3, "dictionary value count")
    var doff = _buf(dict_a[], 1)
    var ddat = _buf(dict_a[], 2)
    assert_equal(Int(doff.bitcast[Int32]()[0]), 0, "dict offsets[0] is 0")
    assert_equal(_utf8_at(doff, ddat, 0), String("AIR"), "dict[0]")
    assert_equal(_utf8_at(doff, ddat, 1), String("RAIL"), "dict[1]")
    assert_equal(_utf8_at(doff, ddat, 2), String("SHIP"), "dict[2]")

    release_c_array(cp)
    cp.free()


def test_nested_struct_children_survive_stream_release() raises:
    """Both children of a STRUCT column, read after the stream is gone.

    A nested child is a separate CArrowArray with its own buffers array; it is
    kept alive here by `Column.share()` recursing into `_children`, not by any
    per-child bookkeeping. This test is what says that recursion happened.
    """
    var sp = _export(_struct_batch(), _struct_schema())
    var cp = _pull(sp)

    release_c_stream(sp)
    assert_true(sp[].is_released(), "stream released")
    sp.free()

    var st = _child(cp[], 0)
    assert_equal(Int(st[].n_children), 2, "struct has 2 children")
    var ka = _child(st[], 0)
    var kb = _child(st[], 1)
    var ints = _buf(ka[], 1).bitcast[Int32]()
    assert_equal(Int(ints[0]), 7, "st.a[0]")
    assert_equal(Int(ints[1]), 8, "st.a[1]")
    assert_equal(Int(ints[2]), 9, "st.a[2]")
    var boff = _buf(kb[], 1)
    var bdat = _buf(kb[], 2)
    assert_equal(_utf8_at(boff, bdat, 0), String("one"), "st.b[0]")
    assert_equal(_utf8_at(boff, bdat, 1), String("two"), "st.b[1]")
    assert_equal(_utf8_at(boff, bdat, 2), String("six"), "st.b[2]")

    release_c_array(cp)
    cp.free()


def test_sibling_chunks_are_independent() raises:
    """Releasing ONE delivered array must not disturb another one.

    Two chunks over the same schema are pulled, chunk 0 is released along with
    the stream, and chunk 1 is then read in full. Both chunks hold shares of
    DIFFERENT batches here, but the test also covers the refcount arithmetic:
    if the fix had transferred ownership rather than shared it, releasing the
    first array would take the bytes with it.
    """
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_wide_batch())
    batches.append(_wide_batch())
    var sp = alloc[CArrowArrayStream](1).unsafe_origin_cast[MutUntrackedOrigin]()
    sp.unsafe_write(CArrowArrayStream())
    build_record_batch_stream(batches^, _wide_schema(), sp)

    var c0 = _pull(sp)
    var c1 = _pull(sp)
    assert_equal(Int(c0[].length), _N, "chunk 0 rows")
    assert_equal(Int(c1[].length), _N, "chunk 1 rows")

    release_c_array(c0)
    c0.free()
    release_c_stream(sp)
    sp.free()

    _assert_wide_chunk(c1[])

    release_c_array(c1)
    c1.free()


def test_release_chunk_before_stream_is_safe_and_idempotent() raises:
    """The other release order, plus double-release.

    The spec fixes no order between releasing a stream and the arrays it
    produced, and says a release callback nulls itself so a second call is a
    no-op. An ownership model that only survives stream-then-array is not the
    model the spec describes.
    """
    var sp = _export(_wide_batch(), _wide_schema())
    var cp = _pull(sp)

    release_c_array(cp)
    assert_true(cp[].is_released(), "chunk released first")
    release_c_array(cp)  # idempotent
    assert_true(cp[].is_released(), "chunk still released")
    cp.free()

    # The stream is still usable: EOF on the next pull, then a clean release.
    var cp2 = _pull(sp)
    assert_true(cp2[].is_released(), "second pull is end-of-stream")
    cp2.free()
    release_c_stream(sp)
    assert_true(sp[].is_released(), "stream released after its chunk")
    release_c_stream(sp)  # idempotent
    assert_true(sp[].is_released(), "stream still released")
    sp.free()


def test_export_import_cycles_do_not_leak() raises:
    """Many export/read/release cycles over one process.

    Shared ownership replaces a use-after-free with a refcount; the failure
    mode that could introduce is the mirror image — an array whose state is
    never dropped, or a share taken and never released. Here the assertion is
    only that every cycle is correct and the process survives.
    """
    for _ in range(512):
        var sp = _export(_wide_batch(), _wide_schema())
        var cp = _pull(sp)
        release_c_stream(sp)
        sp.free()
        _assert_wide_chunk(cp[])
        release_c_array(cp)
        cp.free()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
