# =============================================================================
# ipc_encoder_nested.mojo — Nested Arrow type encoders (own-buffer emit only)
# (nested)
# =============================================================================
#
# Each encoder emits ONLY the parent column's FieldNode + Buffer entries.
# Child-column recursion is performed by the dispatch driver
# (ipc_encoder_dispatch.encode_column) AFTER the parent encoder returns;
# the dispatch driver iterates `col.num_children()` and calls
# `encode_column(col.child_at(i), ...)` directly.
#
# Rationale: a fn-pointer `recurse: EncoderRecurseFn` parameter pattern
# hits a Mojo compiler limitation — function-pointer ALIASES with
# Movable-only payload types (`Column`) cannot be materialized as values
# at call sites (`recurse(col.child_at(0), ...)` errors with "_Self"
# conversion failure). So there is no fn-pointer alias; recursion
# happens in the dispatch driver via direct self-call (the standard
# Mojo recursion idiom used throughout the codebase, e.g. in
# `c_data_stream._export_column_array`).
#
# Coverage:
#   LIST              — validity + Int32 offsets (parent buffers only)
#   STRUCT            — validity only (no value buffer, no offsets)
#   MAP               — validity + Int32 offsets (parent buffers only)
#   UNION_SPARSE      — Int8 type_ids only (NO validity per Arrow spec)
#   UNION_DENSE       — Int8 type_ids + Int32 offsets (NO validity per spec)
#
#   LARGE_LIST        — validity + Int64 offsets (`encode_large_list`)
#
# DICTIONARY: indices half only (`encode_dictionary`); the values are a
# separate DictionaryBatch message.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.ipc_flatbuf import BufferDescriptor, FieldNode
from komira_arrow_ipc.ipc_body_sink import BodySink
from komira_arrow_ipc.ipc_encoder_dispatch import (
    emit_validity_bitmap,
    _align_to_8,
    _align_to_8_zero_pad,
    _copy_bytes_into_body,
)


# =============================================================================
# Internal shared helpers
#
# parametric
# on BodySink (see ipc_body_sink.mojo header). Recursive nested encoders
# (LIST/STRUCT/MAP/UNION) recurse via `encode_column[B]` which threads B
# through the child cascade.
# =============================================================================


def _emit_offsets_buffer[
    B: BodySink
](
    col: Column[HeapRegion],
    offset_bytes: Int,
    n_offsets: Int,
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
) raises -> Int:
    """Emit a LIST/MAP/DENSE_UNION offsets buffer.

    `offset_bytes` is 4 (Int32 offsets) or 8 (Int64 offsets — reserved
    for LARGE_LIST).
    `n_offsets` is the entry count: `length + 1` for LIST / LARGE_LIST /
    MAP (a trailing end offset), `length` for a dense UNION (one offset per
    slot, no trailing entry; Arrow columnar format, "Dense Union").
    `col._offsets` must be set; raises otherwise.
    """
    if not col._offsets:
        raise Error(
            "_emit_offsets_buffer: nested type with no _offsets buffer"
        )
    ref off_ref = col._offsets.value()
    var off_bytes_total = n_offsets * offset_bytes
    if off_bytes_total > off_ref.len():
        raise Error(
            "_emit_offsets_buffer: offsets buffer too small (have "
            + String(off_ref.len())
            + " bytes, need "
            + String(off_bytes_total)
            + ")"
        )
    var aligned = _align_to_8_zero_pad(body, body_cursor)
    _copy_bytes_into_body(body, aligned, off_ref, 0, off_bytes_total)
    buffers.append(
        BufferDescriptor(
            offset=Int64(aligned), length=Int64(off_bytes_total)
        )
    )
    return aligned + off_bytes_total


def _emit_int8_type_ids_buffer[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
) raises -> Int:
    """Emit the UNION type_ids buffer (Int8, one byte per row;
    stored in `col._data`)."""
    var n = col._length
    var aligned = _align_to_8_zero_pad(body, body_cursor)
    _copy_bytes_into_body(body, aligned, col._data, 0, n)
    buffers.append(
        BufferDescriptor(offset=Int64(aligned), length=Int64(n))
    )
    return aligned + n


# =============================================================================
# LIST — emits parent buffers only; child recursion in dispatch driver
# =============================================================================


def encode_list[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """LIST: emit FieldNode + validity + Int32 offsets. Caller (dispatch)
    handles child recursion via `encode_column(col.child_at(0), ...)`.

    Validates that the column has exactly 1 child; the caller relies on
    this when looping `num_children` for the recursion step.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)
    cursor = _emit_offsets_buffer[B](col, 4, col._length + 1, body, cursor, buffers)
    if col.num_children() != 1:
        raise Error(
            "encode_list: expected exactly 1 child, got "
            + String(col.num_children())
        )
    return cursor


def encode_large_list[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """LARGE_LIST: emit FieldNode + validity + Int64 offsets. Caller
    (dispatch) handles child recursion via
    `encode_column(col.child_at(0), ...)`.

    Same shape as `encode_list` but with Int64 offsets (supports >2 GB
    total length). Required when LIST's Int32 offsets would overflow.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)
    cursor = _emit_offsets_buffer[B](col, 8, col._length + 1, body, cursor, buffers)
    if col.num_children() != 1:
        raise Error(
            "encode_large_list: expected exactly 1 child, got "
            + String(col.num_children())
        )
    return cursor


def encode_fixed_size_list[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """FIXED_SIZE_LIST: emit FieldNode + validity ONLY (NO offsets per
    Arrow spec — element count per row is fixed and carried on
    Column._inner_size, NOT inline in buffers). Caller (dispatch)
    recurses into the single child via
    `encode_column(col.child_at(0), ...)`.

    Per Arrow spec, FIXED_SIZE_LIST<T>(N): child column has exactly
    `length * N` elements. The mapping from parent row i to child rows
    [i*N, (i+1)*N) is implicit; no offsets buffer needed.
    """
    if col._inner_size <= 0:
        raise Error(
            "encode_fixed_size_list: _inner_size (element-count-per-row) "
            "must be > 0; got "
            + String(col._inner_size)
        )
    if col.num_children() != 1:
        raise Error(
            "encode_fixed_size_list: expected exactly 1 child, got "
            + String(col.num_children())
        )
    var expected_child_length = col._length * col._inner_size
    var child_length = col.child_at(0)._length
    if child_length != expected_child_length:
        raise Error(
            "encode_fixed_size_list: child length "
            + String(child_length)
            + " != parent_length * _inner_size = "
            + String(expected_child_length)
        )
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)
    return cursor


# =============================================================================
# STRUCT — emits parent buffers only; child recursion in dispatch driver
# =============================================================================


def encode_struct[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """STRUCT: emit FieldNode + validity. Caller (dispatch) iterates
    `num_children` and recurses into each child via `encode_column`.

    STRUCT has NO value buffer and NO offsets buffer — just a validity
    bitmap (per Arrow spec).
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    return emit_validity_bitmap(col, body, body_cursor, buffers)


# =============================================================================
# MAP — emits parent buffers only; child recursion in dispatch driver
# =============================================================================


def encode_map[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """MAP: emit FieldNode + validity + Int32 offsets. Caller (dispatch)
    recurses into the single entries child (STRUCT<key, value>).
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)
    cursor = _emit_offsets_buffer[B](col, 4, col._length + 1, body, cursor, buffers)
    if col.num_children() != 1:
        raise Error(
            "encode_map: expected exactly 1 child (entries STRUCT), got "
            + String(col.num_children())
        )
    return cursor


# =============================================================================
# UNION (sparse + dense) — emits parent buffers only; child recursion in
# dispatch driver
# =============================================================================


def encode_union_sparse[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """UNION_SPARSE: emit FieldNode + Int8 type_ids buffer (NO validity
    per Arrow spec). Caller (dispatch) recurses into N children — sparse
    unions have NO offsets buffer; each child has `length` rows, one per
    Union row.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    return _emit_int8_type_ids_buffer[B](col, body, body_cursor, buffers)


def encode_union_dense[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """UNION_DENSE: emit FieldNode + Int8 type_ids buffer + Int32 offsets
    buffer of `length` entries, with no trailing offset (NO validity per
    Arrow spec). Caller (dispatch) recurses into
    N children — dense unions have a distinct child row per Union row;
    offsets indexes into the child.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = _emit_int8_type_ids_buffer[B](col, body, body_cursor, buffers)
    return _emit_offsets_buffer[B](col, 4, col._length, body, cursor, buffers)


# =============================================================================
# DICTIONARY — indices half (values go in a separate DictionaryBatch)
# =============================================================================


def encode_dictionary[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """DICTIONARY column encoding in a RecordBatch.

    Per Arrow IPC spec, a Dictionary column emits only its INDEX buffer
    in the RecordBatch (validity + Int32 indices buffer). The dictionary
    VALUES are emitted separately as a DictionaryBatch message that
    precedes the first RecordBatch referencing the dict_id.

    This fn emits the indices half (RecordBatch column position). The
    values half is the caller's responsibility via
    `encode_dictionary_batch_message_from_values(...)` (file-level
    driver — typically called by the IPC FileSink). The Field's
    dictionary id is metadata on the Schema, not handled here.

    Storage on Column (set by Column.from_dictionary):
        _data: Int32 indices buffer (1 entry per row)
        _offsets / _dict_data / _dict_size: dictionary VALUES (emitted
            separately via encode_dictionary_batch_message_from_values)
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)
    # indices buffer
    # byte width is driven by Column._dict_index_byte_width (defaults
    # to 4 for legacy `from_dictionary` Int32 path; set to 8 by
    # `from_int64_dict_indices` for >2G dict entries). The Schema-
    # side Field._dict_index_type drives the FB DictionaryEncoding.
    # indexType bit_width independently — both must agree at encode
    # time (caller's responsibility to align Field + Column).
    var n = col._length
    var idx_byte_width = col._dict_index_byte_width
    if idx_byte_width != 4 and idx_byte_width != 8:
        raise Error(
            "encode_dictionary: Column._dict_index_byte_width must be "
            "4 (Int32 v1 default) or 8 (Int64 for >2G dict entries); "
            "got " + String(idx_byte_width)
        )
    var values_bytes = n * idx_byte_width
    cursor = _align_to_8_zero_pad(body, cursor)
    _copy_bytes_into_body(body, cursor, col._data, 0, values_bytes)
    buffers.append(
        BufferDescriptor(offset=Int64(cursor), length=Int64(values_bytes))
    )
    return cursor + values_bytes
