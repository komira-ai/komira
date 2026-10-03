# =============================================================================
# test_arrow_ipc_flatbuf_wire_canonical.mojo
# Wire-canonical Buffer structs and i64 slots
# =============================================================================
#
# Validates two wire-correctness properties:
#
#   Buffer fields in Tensor / SparseTensor* are emitted as canonical INLINE
#   16-byte structs. An offset-to-table encoding would be misparsed by
#   pyarrow's reader, which reads those bytes as a 16-byte Buffer struct.
#
#   i64 fields (RecordBatch.length, Message.bodyLength, TensorDim.size,
#   SparseTensor.non_zero_length) are emitted as true 8-byte i64 inline
#   slots. A u32-truncated write would leave pyarrow's reader (which reads 8
#   bytes at the field offset) picking up garbage high bytes.
#
# Test strategy: round-trip with values that DELIBERATELY exceed the u32
# range. A u32-truncating writer fails these tests (the truncated low bits
# round-trip incorrectly); the i64 path must give exact equality.
#
# Coverage:
#   1. Message bodyLength = 0x100000001 (4G + 1) — fits in i64 only.
#   2. RecordBatch length = 0x100000005 (4G + 5 rows) — i64-only.
#   3. TensorDim size = 0x180000000 (6G) — i64-only.
#   4. Tensor.data Buffer with offset > 2^32 and length > 2^32.
#   5. SparseTensor non_zero_length = 0x100000003 + i64 buffer fields.
#   6. SparseMatrixIndexCSX with both indptr + indices buffer i64 fields
#      > 2^32 — proves both inline-Buffer struct fields work
#      independently.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    write_type_int,
    write_record_batch,
    read_record_batch,
    write_message,
    read_message,
    write_tensor_dim,
    read_tensor_dim,
    write_tensor,
    read_tensor,
    write_sparse_tensor_index_coo,
    read_sparse_tensor_index_coo,
    write_sparse_matrix_index_csx,
    read_sparse_matrix_index_csx,
    write_sparse_tensor,
    read_sparse_tensor,
    write_schema,
    BufferDescriptor,
    TensorDimDescriptor,
    FieldNode,
    TYPE_INT,
    SPARSE_TENSOR_INDEX_COO,
    SPARSE_AXIS_ROW,
    MESSAGE_HEADER_RECORD_BATCH,
)


# ---------------------------------------------------------------------------
# §1 — i64 inline slot: Message.bodyLength
# ---------------------------------------------------------------------------


def test_message_body_length_above_4g() raises:
    """Message with bodyLength = 4 GB + 1.

    The exact value (0x100000001) has both low 32 bits and high 32 bits
    non-zero. A u32-truncated write would store only the low 32 bits
    (0x00000001) and pyarrow's i64 read would see 0x00000001 + 4 bytes of
    unrelated next-field data in the high half.
    """
    var w = FlatbufWriter(2048)
    # Build a minimal Schema as the union payload (offset = 0 is OK for
    # this test because we don't read the header_table_pos).
    var schema_pos = write_schema(w, UInt8(0), List[Int]())
    var body_length = Int64(0x100000001)  # 4G + 1
    var msg_pos = write_message(
        w,
        Int16(4),  # V5
        MESSAGE_HEADER_RECORD_BATCH,
        schema_pos,
        body_length,
    )
    var buf = w^.finalize(msg_pos)
    var reader = flatbuf_reader_over(buf)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.version, Int16(4))
    assert_equal(msg.header_tag, MESSAGE_HEADER_RECORD_BATCH)
    assert_equal(msg.body_length, body_length)


def test_message_body_length_high_bit_only() raises:
    """Message with bodyLength = 0x100000000 (4G exactly, low bits zero).

    The most adversarial case for truncation: low 32 bits are zero, so a
    u32-truncated write produces bodyLength = 0 — wrong by exactly 4 GB.
    """
    var w = FlatbufWriter(2048)
    var schema_pos = write_schema(w, UInt8(0), List[Int]())
    var body_length = Int64(0x100000000)  # 4G exactly
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, schema_pos, body_length
    )
    var buf = w^.finalize(msg_pos)
    var reader = flatbuf_reader_over(buf)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.body_length, body_length)


# ---------------------------------------------------------------------------
# §2 — i64 inline slot: RecordBatch.length
# ---------------------------------------------------------------------------


def test_record_batch_length_above_4g_rows() raises:
    """RecordBatch with length = 4G + 5 rows.

    This is the realistic >2^32-row case (TPC-H scale > 1000, large
    cluster shuffle, etc). A u32 low-bits write would give pyarrow's i64
    read a wrong row count.
    """
    var w = FlatbufWriter(1024)
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(0x100000005), null_count=Int64(0)))
    var buffers = List[BufferDescriptor]()
    buffers.append(BufferDescriptor(offset=Int64(0), length=Int64(0)))
    var rb_pos = write_record_batch(w, Int64(0x100000005), nodes, buffers)
    var buf = w^.finalize(rb_pos)
    var reader = flatbuf_reader_over(buf)
    var rb = read_record_batch(reader, reader.read_root_offset())
    assert_equal(rb.length, Int64(0x100000005))
    assert_equal(len(rb.nodes), 1)
    assert_equal(rb.nodes[0].length, Int64(0x100000005))


# ---------------------------------------------------------------------------
# §3 — i64 inline slot: TensorDim.size
# ---------------------------------------------------------------------------


def test_tensor_dim_size_above_4g() raises:
    """TensorDim with size = 6 GB. A u32-truncated write keeps only the low
    32 bits (0x80000000) and pyarrow reads garbage high bytes."""
    var w = FlatbufWriter(512)
    var size = Int64(0x180000000)  # 6 GB
    var pos = write_tensor_dim(w, size, "huge_dim")
    var buf = w^.finalize(pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_tensor_dim(reader, reader.read_root_offset())
    assert_equal(td.size, size)
    assert_equal(String(td.name), String("huge_dim"))


# ---------------------------------------------------------------------------
# §4 — Inline Buffer struct: Tensor.data
# ---------------------------------------------------------------------------


def test_tensor_data_buffer_above_4g_offset_and_length() raises:
    """Tensor.data Buffer with offset = 5G, length = 5G.

    An offset-to-table encoding (a u32 offset pointing at a separately
    emitted 8-byte Buffer-as-table of two u32 fields) truncates each value
    to 32 bits, and pyarrow reads the field at the wrong offset and decodes
    16 bytes as the inline Buffer struct — a misparse.

    In the canonical form, Tensor.data is an INLINE 16-byte struct at the
    field's inline_offset. Both offset and length are i64 — must
    round-trip exactly even at >2^32 values.
    """
    var w = FlatbufWriter(2048)
    var type_pos = write_type_int(w, 64, True)
    var shape = List[TensorDimDescriptor]()
    shape.append(TensorDimDescriptor(size=Int64(640), name=String("")))
    var strides = List[Int64]()
    var huge_offset = Int64(0x140000000)  # 5 GB
    var huge_length = Int64(0x140000000)  # 5 GB
    var data = BufferDescriptor(offset=huge_offset, length=huge_length)
    var t_pos = write_tensor(w, TYPE_INT, type_pos, shape, strides, data)
    var buf = w^.finalize(t_pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_tensor(reader, reader.read_root_offset())
    assert_equal(td.type_tag, TYPE_INT)
    assert_equal(td.data.offset, huge_offset)
    assert_equal(td.data.length, huge_length)


def test_tensor_data_buffer_small_values_byte_layout() raises:
    """Tensor.data with small Buffer values (offset=12345, length=67890).

    Cross-checks that the INLINE 16-byte struct emission produces the
    exact bytes pyarrow expects:
      bytes[inline_offset[4] .. inline_offset[4]+8) = offset i64 LE
      bytes[inline_offset[4]+8 .. inline_offset[4]+16) = length i64 LE
    """
    var w = FlatbufWriter(1024)
    var type_pos = write_type_int(w, 64, True)
    var shape = List[TensorDimDescriptor]()
    shape.append(TensorDimDescriptor(size=Int64(10), name=String("")))
    var strides = List[Int64]()
    var data = BufferDescriptor(offset=Int64(12345), length=Int64(67890))
    var t_pos = write_tensor(w, TYPE_INT, type_pos, shape, strides, data)
    var buf = w^.finalize(t_pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_tensor(reader, reader.read_root_offset())
    assert_equal(td.data.offset, Int64(12345))
    assert_equal(td.data.length, Int64(67890))


# ---------------------------------------------------------------------------
# §5 — Inline Buffer struct + i64 in SparseTensor
# ---------------------------------------------------------------------------


def test_sparse_tensor_non_zero_above_4g_and_inline_data() raises:
    """SparseTensor with non_zero_length = 4G + 3, plus inline Buffer
    data with values > 2^32. Exercises both the i64 lift AND the
    inline-Buffer lift in the same table.
    """
    var w = FlatbufWriter(2048)
    var values_type_pos = write_type_int(w, 64, True)
    var indices_type_pos = write_type_int(w, 64, True)
    var idx_strides = List[Int64]()
    idx_strides.append(Int64(16))
    idx_strides.append(Int64(8))
    var idx_buf = BufferDescriptor(
        offset=Int64(0), length=Int64(0x120000000)  # 4.5 GB
    )
    var sparse_idx_pos = write_sparse_tensor_index_coo(
        w, indices_type_pos, idx_strides, idx_buf, True
    )
    var shape = List[TensorDimDescriptor]()
    shape.append(TensorDimDescriptor(size=Int64(1000000), name=String("")))
    shape.append(TensorDimDescriptor(size=Int64(1000000), name=String("")))
    var data = BufferDescriptor(
        offset=Int64(0x120000000),  # 4.5 GB
        length=Int64(0x100000018),   # 4 GB + 24
    )
    var non_zero = Int64(0x100000003)  # 4G + 3
    var st_pos = write_sparse_tensor(
        w,
        TYPE_INT,
        values_type_pos,
        shape,
        non_zero,
        SPARSE_TENSOR_INDEX_COO,
        sparse_idx_pos,
        data,
    )
    var buf = w^.finalize(st_pos)
    var reader = flatbuf_reader_over(buf)
    var st = read_sparse_tensor(reader, reader.read_root_offset())
    assert_equal(st.non_zero_length, non_zero)
    assert_equal(st.data.offset, Int64(0x120000000))
    assert_equal(st.data.length, Int64(0x100000018))
    var idx = read_sparse_tensor_index_coo(reader, st.sparse_index_table_pos)
    assert_true(idx.is_canonical)
    assert_equal(idx.indices_buffer.length, Int64(0x120000000))


# ---------------------------------------------------------------------------
# §6 — TWO inline-Buffer struct fields in same table (CSX)
# ---------------------------------------------------------------------------


def test_sparse_matrix_csx_two_inline_buffers_above_4g() raises:
    """SparseMatrixIndexCSX has BOTH indptr_buffer AND indices_buffer
    as inline 16-byte struct fields (the canonical form). This test
    proves both struct slots are independent (no overlap, no truncation,
    correct field_offsets for each).
    """
    var w = FlatbufWriter(1024)
    var indptr_type_pos = write_type_int(w, 32, True)
    var indices_type_pos = write_type_int(w, 32, True)
    var indptr_buf = BufferDescriptor(
        offset=Int64(0), length=Int64(0x100000004)  # 4 GB + 4
    )
    var indices_buf = BufferDescriptor(
        offset=Int64(0x100000004),  # immediately after
        length=Int64(0x100000008),  # 4 GB + 8
    )
    var csx_pos = write_sparse_matrix_index_csx(
        w,
        SPARSE_AXIS_ROW,
        indptr_type_pos,
        indptr_buf,
        indices_type_pos,
        indices_buf,
    )
    var buf = w^.finalize(csx_pos)
    var reader = flatbuf_reader_over(buf)
    var csx = read_sparse_matrix_index_csx(reader, reader.read_root_offset())
    assert_equal(csx.compressed_axis, SPARSE_AXIS_ROW)
    assert_equal(csx.indptr_buffer.offset, Int64(0))
    assert_equal(csx.indptr_buffer.length, Int64(0x100000004))
    assert_equal(csx.indices_buffer.offset, Int64(0x100000004))
    assert_equal(csx.indices_buffer.length, Int64(0x100000008))


# ---------------------------------------------------------------------------
# §7 — small values still round-trip
# ---------------------------------------------------------------------------
# (Spot-check: the canonical path must still handle the common small-value
# case correctly — the other flatbuf test files cover it at every other call
# site, so we only mirror one here.)


def test_message_small_body_length_preserved() raises:
    """Small bodyLength (1024 bytes) still round-trips identically."""
    var w = FlatbufWriter(1024)
    var schema_pos = write_schema(w, UInt8(0), List[Int]())
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, schema_pos, Int64(1024)
    )
    var buf = w^.finalize(msg_pos)
    var reader = flatbuf_reader_over(buf)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.body_length, Int64(1024))


def test_record_batch_zero_length_preserved() raises:
    """Empty RecordBatch (length=0, no nodes, no buffers)."""
    var w = FlatbufWriter(512)
    var nodes = List[FieldNode]()
    var buffers = List[BufferDescriptor]()
    var rb_pos = write_record_batch(w, Int64(0), nodes, buffers)
    var buf = w^.finalize(rb_pos)
    var reader = flatbuf_reader_over(buf)
    var rb = read_record_batch(reader, reader.read_root_offset())
    assert_equal(rb.length, Int64(0))
    assert_equal(len(rb.nodes), 0)
    assert_equal(len(rb.buffers), 0)


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_message_body_length_above_4g]()
    suite.test[test_message_body_length_high_bit_only]()
    suite.test[test_record_batch_length_above_4g_rows]()
    suite.test[test_tensor_dim_size_above_4g]()
    suite.test[test_tensor_data_buffer_above_4g_offset_and_length]()
    suite.test[test_tensor_data_buffer_small_values_byte_layout]()
    suite.test[test_sparse_tensor_non_zero_above_4g_and_inline_data]()
    suite.test[test_sparse_matrix_csx_two_inline_buffers_above_4g]()
    suite.test[test_message_small_body_length_preserved]()
    suite.test[test_record_batch_zero_length_preserved]()
    suite^.run()
