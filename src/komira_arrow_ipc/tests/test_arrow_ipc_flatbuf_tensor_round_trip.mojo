# =============================================================================
# test_arrow_ipc_flatbuf_tensor_round_trip.mojo — Tensor flatbuffers
# =============================================================================
#
# Validates Tensor + SparseTensor + SparseTensorIndex variants.
#
# Tests are INTERNAL ROUND-TRIP ONLY at this layer — the Buffer-as-table
# encoding used here is non-canonical (canonical Arrow IPC has inline Buffer
# structs), so wire-compatibility with pyarrow/arrow-rs needs an
# inline-struct extension to _TableBuilder.
#
# Coverage:
#   1. TensorDim round-trip.
#   2. Tensor 1D round-trip (Int64).
#   3. Tensor 2D round-trip with strides + named dims.
#   4. SparseTensorIndexCOO round-trip.
#   5. SparseMatrixIndexCSX round-trip.
#   6. SparseTensor with COO index round-trip.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    write_type_int,
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
    BufferDescriptor,
    TensorDimDescriptor,
    TYPE_INT,
    SPARSE_TENSOR_INDEX_COO,
    SPARSE_TENSOR_INDEX_CSX,
    SPARSE_AXIS_ROW,
    SPARSE_AXIS_COLUMN,
)


# ---------------------------------------------------------------------------
# TensorDim round-trip
# ---------------------------------------------------------------------------


def test_tensor_dim_with_name() raises:
    """TensorDim(size=256, name="height")."""
    var w = FlatbufWriter(512)
    var pos = write_tensor_dim(w, Int64(256), "height")
    var buf = w^.finalize(pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_tensor_dim(reader, reader.read_root_offset())
    assert_equal(td.size, Int64(256))
    assert_equal(String(td.name), String("height"))


def test_tensor_dim_no_name() raises:
    """TensorDim(size=128, name="") — no dim label."""
    var w = FlatbufWriter(512)
    var pos = write_tensor_dim(w, Int64(128), "")
    var buf = w^.finalize(pos)
    var reader = flatbuf_reader_over(buf)
    var td = read_tensor_dim(reader, reader.read_root_offset())
    assert_equal(td.size, Int64(128))
    assert_equal(td.name.byte_length(), 0)


# ---------------------------------------------------------------------------
# Tensor round-trip
# ---------------------------------------------------------------------------


def test_tensor_1d_int64() raises:
    """1D Int64 Tensor with shape=[100] + no strides."""
    var w = FlatbufWriter(2048)
    var type_pos = write_type_int(w, 64, True)
    var shape = List[TensorDimDescriptor]()
    shape.append(TensorDimDescriptor(size=Int64(100), name=String("")))
    var strides = List[Int64]()
    var data = BufferDescriptor(offset=Int64(0), length=Int64(800))  # 100 × 8 bytes
    var t_pos = write_tensor(w, TYPE_INT, type_pos, shape, strides, data)
    var buf = w^.finalize(t_pos)

    var reader = flatbuf_reader_over(buf)
    var td = read_tensor(reader, reader.read_root_offset())
    assert_equal(td.type_tag, TYPE_INT)
    assert_true(td.type_table_pos > 0)
    assert_equal(len(td.shape), 1)
    assert_equal(td.shape[0].size, Int64(100))
    assert_equal(len(td.strides), 0)
    assert_equal(td.data.offset, Int64(0))
    assert_equal(td.data.length, Int64(800))


def test_tensor_2d_with_strides_named() raises:
    """2D Tensor 32x64 with named dims + explicit row-major strides."""
    var w = FlatbufWriter(2048)
    var type_pos = write_type_int(w, 64, True)
    var shape = List[TensorDimDescriptor]()
    shape.append(TensorDimDescriptor(size=Int64(32), name=String("rows")))
    shape.append(TensorDimDescriptor(size=Int64(64), name=String("cols")))
    var strides = List[Int64]()
    strides.append(Int64(512))  # row stride = 64 * 8 bytes
    strides.append(Int64(8))    # col stride = 8 bytes (Int64)
    var data = BufferDescriptor(offset=Int64(0), length=Int64(16384))  # 32 * 64 * 8
    var t_pos = write_tensor(w, TYPE_INT, type_pos, shape, strides, data)
    var buf = w^.finalize(t_pos)

    var reader = flatbuf_reader_over(buf)
    var td = read_tensor(reader, reader.read_root_offset())
    assert_equal(len(td.shape), 2)
    assert_equal(td.shape[0].size, Int64(32))
    assert_equal(String(td.shape[0].name), String("rows"))
    assert_equal(td.shape[1].size, Int64(64))
    assert_equal(String(td.shape[1].name), String("cols"))
    assert_equal(len(td.strides), 2)
    assert_equal(td.strides[0], Int64(512))
    assert_equal(td.strides[1], Int64(8))
    assert_equal(td.data.length, Int64(16384))


# ---------------------------------------------------------------------------
# SparseTensorIndexCOO + CSX round-trip
# ---------------------------------------------------------------------------


def test_sparse_tensor_index_coo_canonical() raises:
    """SparseTensorIndexCOO with canonical=True."""
    var w = FlatbufWriter(1024)
    var indices_type_pos = write_type_int(w, 64, True)
    var strides = List[Int64]()
    strides.append(Int64(16))  # 2 axes × 8 bytes each
    strides.append(Int64(8))
    var indices_buf = BufferDescriptor(offset=Int64(0), length=Int64(160))
    var idx_pos = write_sparse_tensor_index_coo(
        w, indices_type_pos, strides, indices_buf, True
    )
    var buf = w^.finalize(idx_pos)

    var reader = flatbuf_reader_over(buf)
    var idx = read_sparse_tensor_index_coo(reader, reader.read_root_offset())
    assert_true(idx.is_canonical)
    assert_equal(len(idx.indices_strides), 2)
    assert_equal(idx.indices_strides[0], Int64(16))
    assert_equal(idx.indices_buffer.length, Int64(160))


def test_sparse_matrix_index_csx_row_compressed() raises:
    """SparseMatrixIndexCSX with row-compressed (CSR-style) layout."""
    var w = FlatbufWriter(1024)
    var indptr_type_pos = write_type_int(w, 32, True)
    var indices_type_pos = write_type_int(w, 32, True)
    var indptr_buf = BufferDescriptor(offset=Int64(0), length=Int64(132))  # (32+1)*4
    var indices_buf = BufferDescriptor(offset=Int64(132), length=Int64(80))
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
    assert_equal(csx.indptr_buffer.length, Int64(132))
    assert_equal(csx.indices_buffer.offset, Int64(132))
    assert_equal(csx.indices_buffer.length, Int64(80))


# ---------------------------------------------------------------------------
# SparseTensor with COO index round-trip
# ---------------------------------------------------------------------------


def test_sparse_tensor_coo_2d() raises:
    """2D SparseTensor with COO index, 5 non-zero elements."""
    var w = FlatbufWriter(2048)
    var values_type_pos = write_type_int(w, 64, True)
    var indices_type_pos = write_type_int(w, 64, True)
    # Build the COO index first.
    var idx_strides = List[Int64]()
    idx_strides.append(Int64(16))
    idx_strides.append(Int64(8))
    var idx_buf = BufferDescriptor(offset=Int64(0), length=Int64(80))  # 5 * 2 * 8
    var sparse_idx_pos = write_sparse_tensor_index_coo(
        w, indices_type_pos, idx_strides, idx_buf, True
    )
    # Now the SparseTensor itself.
    var shape = List[TensorDimDescriptor]()
    shape.append(TensorDimDescriptor(size=Int64(100), name=String("")))
    shape.append(TensorDimDescriptor(size=Int64(100), name=String("")))
    var data = BufferDescriptor(offset=Int64(80), length=Int64(40))  # 5 * 8
    var st_pos = write_sparse_tensor(
        w,
        TYPE_INT,
        values_type_pos,
        shape,
        Int64(5),
        SPARSE_TENSOR_INDEX_COO,
        sparse_idx_pos,
        data,
    )
    var buf = w^.finalize(st_pos)

    var reader = flatbuf_reader_over(buf)
    var st = read_sparse_tensor(reader, reader.read_root_offset())
    assert_equal(st.type_tag, TYPE_INT)
    assert_equal(len(st.shape), 2)
    assert_equal(st.shape[0].size, Int64(100))
    assert_equal(st.non_zero_length, Int64(5))
    assert_equal(st.sparse_index_tag, SPARSE_TENSOR_INDEX_COO)
    assert_equal(st.data.length, Int64(40))
    # Walk into the COO index.
    var idx = read_sparse_tensor_index_coo(reader, st.sparse_index_table_pos)
    assert_true(idx.is_canonical)
    assert_equal(idx.indices_buffer.length, Int64(80))


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_tensor_dim_with_name]()
    suite.test[test_tensor_dim_no_name]()
    suite.test[test_tensor_1d_int64]()
    suite.test[test_tensor_2d_with_strides_named]()
    suite.test[test_sparse_tensor_index_coo_canonical]()
    suite.test[test_sparse_matrix_index_csx_row_compressed]()
    suite.test[test_sparse_tensor_coo_2d]()
    suite^.run()
