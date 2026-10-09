# =============================================================================
# test_arrow_ipc_flatbuf_builder_edges.mojo: the flatbuffer builder's and
# reader's edges that well-formed Arrow messages never reach
# =============================================================================
#
#   * add_field_* ignore a field id outside [0, 16) (and add_field_offset a
#     target outside [0, 2^31)): the table is the one without that field;
#     end_table refuses a field width none of them records;
#   * the vtable cache tells apart two shapes with the same field count and
#     inline size, and stops recording after 64 shapes (a later table still
#     emits a correct vtable of its own);
#   * write_offset_u32 refuses a target before its slot; read_offset_u32
#     refuses a target outside the buffer; the table-field readers refuse a
#     vtable before the buffer start, and return an empty Buffer for an
#     absent inline-struct field;
#   * each table reader refuses a table without its required offset field;
#   * write_ipc_message zero-pads a payload that is not a multiple of 8;
#   * the vtable cache neither records nor finds a shape of more than 16
#     fields (add_field_* cannot build one, so the private helpers are
#     called directly), and does record and find a 16-field shape.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FlatbufReader,
    FlatbufWriter,
    MAX_VTABLE_FIELDS,
    add_field_bool,
    add_field_i64,
    add_field_inline_struct,
    add_field_offset,
    add_field_u16,
    add_field_u32,
    add_field_u8,
    end_table,
    flatbuf_reader_over,
    read_dictionary_batch,
    read_message,
    read_sparse_matrix_index_csx,
    read_sparse_tensor,
    read_sparse_tensor_index_coo,
    read_tensor,
    start_table,
    write_ipc_message,
    write_type_int,
    _read_table_field_buffer_inline,
    _read_table_field_i64,
    _read_table_field_offset,
    _read_table_field_u32,
)


# ---------------------------------------------------------------------------
# Out-of-range field ids
# ---------------------------------------------------------------------------


def test_out_of_range_field_ids_are_ignored() raises:
    var w = FlatbufWriter(1024)
    var target = write_type_int(w, 32, True)
    var tb = start_table()
    add_field_u32(tb, 16, UInt32(1))
    add_field_u32(tb, -1, UInt32(1))
    add_field_u16(tb, 16, UInt16(2))
    add_field_u8(tb, 16, UInt8(3))
    add_field_bool(tb, -1, True)
    add_field_i64(tb, 16, Int64(4))
    add_field_offset(tb, 16, target)
    add_field_offset(tb, 1, -1)
    add_field_offset(tb, 1, 0x80000000)
    var junk = List[UInt8]()
    for i in range(16):
        junk.append(UInt8(i))
    add_field_inline_struct(tb, 16, junk^)
    assert_equal(tb._field_count, 0)
    add_field_u32(tb, 0, UInt32(42))
    assert_equal(tb._field_count, 1)
    var pos = end_table(w, tb^)
    var buf = w^.finalize(pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    assert_equal(_read_table_field_u32(r, root, 0), UInt32(42))
    assert_equal(_read_table_field_offset(r, root, 1), -1)
    # The vtable holds one field slot: [u16 size, u16 inline, u16 slot0].
    var vt = root - Int(r.read_i32_le(root))
    assert_equal(Int(r.read_u16_le(vt)), 6)


# ---------------------------------------------------------------------------
# The vtable cache
# ---------------------------------------------------------------------------


def test_same_count_and_size_with_other_offsets_is_not_deduped() raises:
    """A = {0: u32 7, 2: u32 9}, B = {1: u32 8, 2: u32 10}: both have 3
    fields and 8 inline bytes, and their slot offsets differ at field 0. If
    B reused A's vtable it would read 8 as field 0."""
    var w = FlatbufWriter(1024)
    var ta = start_table()
    add_field_u32(ta, 0, UInt32(7))
    add_field_u32(ta, 2, UInt32(9))
    var a = end_table(w, ta^)
    var tb = start_table()
    add_field_u32(tb, 1, UInt32(8))
    add_field_u32(tb, 2, UInt32(10))
    var b = end_table(w, tb^)
    var outer = start_table()
    add_field_offset(outer, 0, a)
    add_field_offset(outer, 1, b)
    var root_pos = end_table(w, outer^)
    var buf = w^.finalize(root_pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    var pa = _read_table_field_offset(r, root, 0)
    var pb = _read_table_field_offset(r, root, 1)
    assert_equal(_read_table_field_u32(r, pa, 0), UInt32(7))
    assert_equal(_read_table_field_offset(r, pa, 1), -1)
    assert_equal(_read_table_field_u32(r, pa, 2), UInt32(9))
    assert_equal(_read_table_field_offset(r, pb, 0), -1)
    assert_equal(_read_table_field_u32(r, pb, 1), UInt32(8))
    assert_equal(_read_table_field_u32(r, pb, 2), UInt32(10))


def _one_field_table(mut w: FlatbufWriter, kind: Int, id: Int) raises -> Int:
    """A table whose only field is `id`, of width 4 (kind 0), 1 (kind 1),
    2 (kind 2) or 8 (kind 3), holding 100 + id."""
    var tb = start_table()
    if kind == 0:
        add_field_u32(tb, id, UInt32(100 + id))
    elif kind == 1:
        add_field_u8(tb, id, UInt8(100 + id))
    elif kind == 2:
        add_field_u16(tb, id, UInt16(100 + id))
    else:
        add_field_i64(tb, id, Int64(100 + id))
    return end_table(w, tb^)


def _vtable_of[
    o: Origin[mut=False]
](r: FlatbufReader[o], table: Int) raises -> Int:
    return table - Int(r.read_i32_le(table))


def test_the_cache_stops_at_64_shapes_and_tables_stay_correct() raises:
    """64 distinct one-field shapes fill the cache. A 65th shape is not
    recorded, so two tables of it each get a vtable of their own; a table
    of a cached shape shares the cached vtable; every table reads back its
    values."""
    var w = FlatbufWriter(16384)
    var positions = List[Int]()
    for kind in range(4):
        for id in range(16):
            positions.append(_one_field_table(w, kind, id))
    var t1 = start_table()
    add_field_u32(t1, 0, UInt32(1))
    add_field_u32(t1, 1, UInt32(2))
    var p65 = end_table(w, t1^)
    var t2 = start_table()
    add_field_u32(t2, 0, UInt32(3))
    add_field_u32(t2, 1, UInt32(4))
    var p66 = end_table(w, t2^)
    var pc = _one_field_table(w, 0, 0)
    var outer = start_table()
    add_field_offset(outer, 0, p65)
    add_field_offset(outer, 1, p66)
    add_field_offset(outer, 2, pc)
    add_field_offset(outer, 3, positions[63])
    add_field_offset(outer, 4, positions[0])
    var root_pos = end_table(w, outer^)
    var buf = w^.finalize(root_pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    var a = _read_table_field_offset(r, root, 0)
    var b = _read_table_field_offset(r, root, 1)
    var c = _read_table_field_offset(r, root, 2)
    var d = _read_table_field_offset(r, root, 3)
    var first = _read_table_field_offset(r, root, 4)
    assert_true(_vtable_of(r, a) != _vtable_of(r, b))
    assert_equal(_vtable_of(r, c), _vtable_of(r, first))
    assert_equal(_read_table_field_u32(r, a, 0), UInt32(1))
    assert_equal(_read_table_field_u32(r, a, 1), UInt32(2))
    assert_equal(_read_table_field_u32(r, b, 0), UInt32(3))
    assert_equal(_read_table_field_u32(r, b, 1), UInt32(4))
    assert_equal(_read_table_field_u32(r, c, 0), UInt32(100))
    assert_equal(_read_table_field_i64(r, d, 15), Int64(115))


def test_end_table_refuses_a_field_width_no_writer_records() raises:
    """add_field_* record widths 1, 2, 4 and 8 (or an inline struct); a
    builder carrying any other width is refused by name rather than
    emitted with a wrong layout."""
    var w = FlatbufWriter(256)
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(5))
    tb._field_widths[0] = UInt8(3)
    var msg = String("")
    try:
        _ = end_table(w, tb^)
    except e:
        msg = String(e)
    assert_equal(msg, "end_table: unsupported field width 3 at field_id=0")


# ---------------------------------------------------------------------------
# Offset and vtable refusals
# ---------------------------------------------------------------------------


def test_writer_refuses_an_offset_to_a_target_before_its_slot() raises:
    var w = FlatbufWriter(64)
    var msg = String("")
    try:
        w.write_offset_u32(0)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "FlatbufWriter: offset target (0) precedes offset slot (60);"
        " back-to-front writer expects target-after-slot",
    )


def _bytes(var words: List[Int32]) raises -> SharedAlignedBuffer[HeapRegion]:
    var b = SharedAlignedBuffer[HeapRegion].heap_owned(len(words) * 4)
    for i in range(len(words)):
        b.write_i32_le_at(i * 4, words[i])
    b.set_length(len(words) * 4)
    return b^


def test_reader_refuses_an_offset_outside_the_buffer() raises:
    var words = List[Int32]()
    words.append(100)
    words.append(0)
    var buf = _bytes(words^)
    var r = flatbuf_reader_over(buf)
    var msg = String("")
    try:
        _ = r.read_offset_u32(0)
    except e:
        msg = String(e)
    assert_equal(msg, "FlatbufReader: offset target (100) out of bounds [0, 8)")


def test_field_readers_refuse_a_vtable_before_the_buffer() raises:
    """A table at 4 whose soffset (100) puts its vtable at -96."""
    var words = List[Int32]()
    words.append(4)
    words.append(100)
    words.append(0)
    var buf = _bytes(words^)
    var r = flatbuf_reader_over(buf)
    var msgs = List[String]()
    try:
        _ = _read_table_field_offset(r, 4, 0)
    except e:
        msgs.append(String(e))
    try:
        _ = _read_table_field_i64(r, 4, 0)
    except e:
        msgs.append(String(e))
    try:
        _ = _read_table_field_buffer_inline(r, 4, 0)
    except e:
        msgs.append(String(e))
    assert_equal(len(msgs), 3)
    for i in range(3):
        assert_equal(msgs[i], "FlatbufReader: invalid vtable position")


def test_absent_inline_buffer_reads_as_empty() raises:
    """Field 1 absent inside the vtable (fields 0 and 2 present), and field
    5 beyond it: both read as Buffer{0, 0}; field 2 reads its bytes."""
    var w = FlatbufWriter(1024)
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(1))
    var bytes = List[UInt8]()
    for i in range(16):
        bytes.append(UInt8(i + 1))
    add_field_inline_struct(tb, 2, bytes^)
    var pos = end_table(w, tb^)
    var buf = w^.finalize(pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    var absent = _read_table_field_buffer_inline(r, root, 1)
    assert_equal(absent.offset, Int64(0))
    assert_equal(absent.length, Int64(0))
    var beyond = _read_table_field_buffer_inline(r, root, 5)
    assert_equal(beyond.offset, Int64(0))
    assert_equal(beyond.length, Int64(0))
    var present = _read_table_field_buffer_inline(r, root, 2)
    assert_equal(present.offset, Int64(0x0807060504030201))
    assert_equal(present.length, Int64(0x100F0E0D0C0B0A09))


# ---------------------------------------------------------------------------
# Required fields
# ---------------------------------------------------------------------------


def _table_error(
    reader_kind: Int, var present: List[Int]
) raises -> String:
    """A table whose fields `present` hold an offset to an Int type table
    (an inline u8 for field ids above 99, minus 100), read by reader
    `reader_kind`; returns the refusal text."""
    var w = FlatbufWriter(1024)
    var t = write_type_int(w, 32, True)
    var tb = start_table()
    for i in range(len(present)):
        if present[i] >= 100:
            add_field_u8(tb, present[i] - 100, UInt8(1))
        else:
            add_field_offset(tb, present[i], t)
    var pos = end_table(w, tb^)
    var buf = w^.finalize(pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    try:
        if reader_kind == 0:
            _ = read_message(r, root)
        elif reader_kind == 1:
            _ = read_dictionary_batch(r, root)
        elif reader_kind == 2:
            _ = read_tensor(r, root)
        elif reader_kind == 3:
            _ = read_sparse_tensor_index_coo(r, root)
        elif reader_kind == 4:
            _ = read_sparse_matrix_index_csx(r, root)
        else:
            _ = read_sparse_tensor(r, root)
    except e:
        return String(e)
    return String("no error")


def _ids(a: Int, b: Int = -1) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    if b >= 0:
        out.append(b)
    return out^


def test_table_readers_refuse_a_missing_required_field() raises:
    assert_equal(_table_error(0, _ids(101)), "Message: header field missing")
    assert_equal(
        _table_error(1, _ids(103)), "DictionaryBatch: data field missing"
    )
    assert_equal(_table_error(2, _ids(100)), "Tensor: type field missing")
    assert_equal(
        _table_error(3, _ids(1)),
        "SparseTensorIndexCOO: indicesType field missing",
    )
    # CSX needs both type fields (1 and 3): either one alone is refused.
    assert_equal(
        _table_error(4, _ids(1)),
        "SparseMatrixIndexCSX: required type field missing",
    )
    assert_equal(
        _table_error(4, _ids(3)),
        "SparseMatrixIndexCSX: required type field missing",
    )
    assert_equal(_table_error(5, _ids(100)), "SparseTensor: type field missing")
    assert_equal(
        _table_error(5, _ids(1)), "SparseTensor: sparseIndex field missing"
    )


# ---------------------------------------------------------------------------
# Framing
# ---------------------------------------------------------------------------


def test_write_ipc_message_pads_the_payload_to_8() raises:
    """A 5-byte payload is framed as metadata size 8: the payload, 3 zero
    bytes, then the body."""
    var payload = SharedAlignedBuffer[HeapRegion].heap_owned(5)
    for i in range(5):
        payload.write_u8_at(i, UInt8(0xA0 + i))
    payload.set_length(5)
    var body = List[UInt8]()
    body.append(UInt8(0x11))
    body.append(UInt8(0x22))
    var w = FlatbufWriter(64)
    var frame = write_ipc_message(w, payload^, Span(body), True)
    assert_equal(frame.len(), 4 + 4 + 8 + 2)
    assert_equal(frame.read_u32_le_at(0), UInt32(0xFFFFFFFF))
    assert_equal(frame.read_u32_le_at(4), UInt32(8))
    for i in range(5):
        assert_equal(frame.read_u8_at(8 + i), UInt8(0xA0 + i))
    for i in range(3):
        assert_equal(frame.read_u8_at(13 + i), UInt8(0))
    assert_equal(frame.read_u8_at(16), UInt8(0x11))
    assert_equal(frame.read_u8_at(17), UInt8(0x22))


# ---------------------------------------------------------------------------
# Vtable cache: shapes wider than MAX_VTABLE_FIELDS
# ---------------------------------------------------------------------------


def test_the_cache_skips_a_shape_wider_than_16_fields() raises:
    """_vtable_record does not record a shape of 17 fields and
    _vtable_lookup answers -1 for one, even with a cached shape of the
    same inline size; a shape of exactly 16 fields is recorded and found.
    add_field_* ignore ids >= 16, so only a direct call builds such a
    shape."""
    var w = FlatbufWriter(256)
    var offs = Array[Int32, MAX_VTABLE_FIELDS](fill=Int32(0))
    offs[0] = Int32(4)
    w._vtable_record(MAX_VTABLE_FIELDS + 1, 8, offs, 40)
    assert_equal(w._vt_count, 0)
    assert_equal(w._vtable_lookup(MAX_VTABLE_FIELDS + 1, 8, offs), -1)
    w._vtable_record(MAX_VTABLE_FIELDS, 8, offs, 40)
    assert_equal(w._vt_count, 1)
    assert_equal(w._vtable_lookup(MAX_VTABLE_FIELDS, 8, offs), 40)
    assert_equal(w._vtable_lookup(MAX_VTABLE_FIELDS + 1, 8, offs), -1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
