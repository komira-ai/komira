# =============================================================================
# ipc_encoder_temporal.mojo — Temporal + decimal Arrow type encoders
# (temporal and decimal)
# =============================================================================
#
# Temporal + decimal types' value buffers are storage-DType-compatible
# with primitive int32/int64/byte-slab. The encoder
# body is SHARED with primitive int32/int64/byte-slab — only the FieldNode
# emission differs (which is identical). The encoders here are thin
# delegations to the fixed-width primitive shared body.
#
# Type variant-arm differences (e.g. Date{DAY} vs Date{MILLISECOND},
# Timestamp{S,MS,US,NS,+tz}) live in the SCHEMA encoder (the Schema
# message write path), NOT in the per-RecordBatch buffer encoder
# here.
#
# Coverage (15 ArrowType variants):
#   Date32 (i32), Date64 (i64)
#   Time32_S (i32), Time32_MS (i32), Time64_US (i64), Time64_NS (i64)
#   Timestamp (i64), Timestamp_S/MS/US/NS (i64; 4 ratified variants)
#   Duration_S/MS/US/NS (i64)
#   Interval_YearMonth (i32), Interval_DayTime (i64; 2× i32 packed),
#   Interval_MonthDayNano (16-byte slab)
#   Decimal128 (16-byte slab), Decimal256 (32-byte slab)
# =============================================================================

from komira_core.arrow.column import Column
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.ipc_flatbuf import BufferDescriptor, FieldNode
from .ipc_body_sink import BodySink
from .ipc_encoder_primitive import _encode_fixed_width_primitive


# =============================================================================
# Date / Time variants
#
# parametric
# on BodySink (see ipc_body_sink.mojo header).
# =============================================================================


def encode_date32[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """DATE32: days since epoch (Int32 storage)."""
    return _encode_fixed_width_primitive[B](
        col, 4, body, body_cursor, buffers, nodes
    )


def encode_date64[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """DATE64: milliseconds since epoch (Int64 storage)."""
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


def encode_time32[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """TIME32 ({SECOND, MILLISECOND} unit; Int32 storage)."""
    return _encode_fixed_width_primitive[B](
        col, 4, body, body_cursor, buffers, nodes
    )


def encode_time64[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """TIME64 ({MICRO, NANO} unit; Int64 storage)."""
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


# =============================================================================
# Timestamp + Duration (all Int64)
# =============================================================================


def encode_timestamp[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """TIMESTAMP (all 4 ratified units + ±tz; Int64 storage)."""
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


def encode_duration[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """DURATION (4 units; Int64 storage)."""
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


# =============================================================================
# Interval variants
# =============================================================================


def encode_interval_ym[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """INTERVAL_YEAR_MONTH: Int32 storage."""
    return _encode_fixed_width_primitive[B](
        col, 4, body, body_cursor, buffers, nodes
    )


def encode_interval_dt[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """INTERVAL_DAY_TIME: Int64 storage (2× Int32 packed)."""
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


def encode_interval_mdn[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """INTERVAL_MONTH_DAY_NANO: 16-byte slab per row."""
    return _encode_fixed_width_primitive[B](
        col, 16, body, body_cursor, buffers, nodes
    )


# =============================================================================
# Decimal variants
# =============================================================================


def encode_decimal128[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """DECIMAL128: 16-byte slab per row."""
    return _encode_fixed_width_primitive[B](
        col, 16, body, body_cursor, buffers, nodes
    )


def encode_decimal256[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """DECIMAL256: 32-byte slab per row."""
    return _encode_fixed_width_primitive[B](
        col, 32, body, body_cursor, buffers, nodes
    )


def encode_fixed_size_binary[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """FIXED_SIZE_BINARY: variable byte_width per row (carried on
    Column._inner_size). Same emit shape as DECIMAL128/256 with
    byte-slab values + validity bitmap; byte_width comes from
    `_inner_size` rather than being hardcoded.

    """
    if col._inner_size <= 0:
        raise Error(
            "encode_fixed_size_binary: _inner_size must be > 0; got "
            + String(col._inner_size)
            + " (set via Column.from_fixed_size_binary(... byte_width=N ...))"
        )
    return _encode_fixed_width_primitive[B](
        col, col._inner_size, body, body_cursor, buffers, nodes
    )
