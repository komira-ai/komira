# =============================================================================
# ocf_col_encode.mojo — the OCF writer's per-column write plan and per-cell
# value encode (used by avro_ocf_writer.mojo).
# =============================================================================
#
# `_build_col_encoders` resolves each column's Arrow type to a write-action tag
# and fetches its typed array once per batch; `_encode_one_cell` encodes one
# cell from that pre-fetched array. No UnsafePointer crosses the module
# boundary.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from .varint_encode import (
    encode_long,
    encode_int,
    encode_boolean,
    encode_float,
    encode_double,
    encode_bytes,
    encode_union_tag,
)

# =============================================================================
# Per-column write plan (type resolution hoisted out of the row loop).
# =============================================================================
#
# arrow-avro resolves each column's encoder ONCE per batch (`prepare_for_batch`)
# then the row loop just calls the already-typed encoder. Resolving per cell
# would re-walk a 17-branch `ArrowType` if/elif cascade for EVERY one of
# N_cols × N_rows cells — and, far worse, call `batch.column_as_*(col)` per
# cell, each of which DEEP-COPIES the whole column buffer (column.mojo
# as_primitive/as_string/as_boolean all memcpy): one full-column copy per row.
#
# The fix: `_build_col_encoders` runs ONCE before the row loop. It (a) resolves
# each column's write action into a small integer tag, and (b) fetches the
# typed Arrow array ONCE (one copy per column for the whole file, not per row).
# The row loop then dispatches on the tag and indexes the pre-fetched array via
# `arr.get(row)` (O(1)) — no cascade, no per-cell column copy.

# Write-action tags. Grouped by the Avro wire encoder they drive.
comptime _WA_INT32: Int = 0  # Avro int  (bare INT32 + TIME32_S)
comptime _WA_INT8: Int = 1  # Avro int  (widen narrow signed/unsigned -> int)
comptime _WA_INT16: Int = 2
comptime _WA_UINT8: Int = 3
comptime _WA_UINT16: Int = 4
comptime _WA_INT64: Int = 5  # Avro long (bare INT64 + long-backed logicals)
comptime _WA_UINT32: Int = 6  # Avro long (widen uint32 -> long)
comptime _WA_FLOAT32: Int = 7
comptime _WA_FLOAT64: Int = 8
comptime _WA_BOOL: Int = 9
comptime _WA_STRING: Int = 10  # STRING (int32 offsets, zero-copy span)
comptime _WA_BINARY: Int = 11  # BINARY / LARGE_BINARY (zero-copy span)
# ⚠ LARGE_STRING NEEDS ITS OWN TAG. `column_as_string` returns an int32-offset
# array by definition, so resolving a PROMOTED column through it raises
# `Column.as_string: arrow_type is large_string`.
# The Avro wire bytes are identical either way (a `bytes`/`string` value is a
# zig-zag length followed by the UTF-8 payload); only the offset width used to
# FIND the payload differs, which is why this is a separate tag and not a
# separate encoder.
comptime _WA_LARGE_STRING: Int = 12  # LARGE_STRING (int64 offsets, zero-copy span)


struct _ColEncoder(Movable):
    """A pre-resolved per-column encoder: the write-action tag + nullability +
    the typed Arrow array fetched ONCE. Exactly one of the typed-array
    optionals is populated, selected by `tag`.

    The narrow signed/unsigned logicals (int8/16, uint8/16) share the int32
    slot path via their own optionals so the per-cell widen-cast stays O(1)
    on the already-fetched array; uint32 shares the int64 long path."""

    var tag: Int
    var nullable: Bool
    var i32: Optional[PrimitiveArray[DType.int32]]
    var i8: Optional[PrimitiveArray[DType.int8]]
    var i16: Optional[PrimitiveArray[DType.int16]]
    var u8: Optional[PrimitiveArray[DType.uint8]]
    var u16: Optional[PrimitiveArray[DType.uint16]]
    var i64: Optional[PrimitiveArray[DType.int64]]
    var u32: Optional[PrimitiveArray[DType.uint32]]
    var f32: Optional[PrimitiveArray[DType.float32]]
    var f64: Optional[PrimitiveArray[DType.float64]]
    var b: Optional[BooleanArray]
    var s: Optional[StringArray[HeapRegion]]
    var ls: Optional[LargeStringArray[HeapRegion]]

    def __init__(out self, tag: Int, nullable: Bool):
        self.tag = tag
        self.nullable = nullable
        self.i32 = None
        self.i8 = None
        self.i16 = None
        self.u8 = None
        self.u16 = None
        self.i64 = None
        self.u32 = None
        self.f32 = None
        self.f64 = None
        self.b = None
        self.s = None
        self.ls = None


def _resolve_write_tag(at: ArrowType) -> Int:
    """Resolve the per-column write-action tag (-1 if unsupported)."""
    if at == ArrowType.INT32 or at == ArrowType.TIME32_S:
        return _WA_INT32
    elif at == ArrowType.INT8:
        return _WA_INT8
    elif at == ArrowType.INT16:
        return _WA_INT16
    elif at == ArrowType.UINT8:
        return _WA_UINT8
    elif at == ArrowType.UINT16:
        return _WA_UINT16
    elif (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_NS
        or at == ArrowType.TIME64_NS
        or at == ArrowType.DURATION_S
        or at == ArrowType.DURATION_MS
        or at == ArrowType.DURATION_US
        or at == ArrowType.DURATION_NS
    ):
        return _WA_INT64
    elif at == ArrowType.UINT32:
        return _WA_UINT32
    elif at == ArrowType.FLOAT32:
        return _WA_FLOAT32
    elif at == ArrowType.FLOAT64:
        return _WA_FLOAT64
    elif at == ArrowType.BOOL:
        return _WA_BOOL
    elif at == ArrowType.STRING:
        return _WA_STRING
    elif at == ArrowType.LARGE_STRING:
        return _WA_LARGE_STRING
    elif at == ArrowType.BINARY or at == ArrowType.LARGE_BINARY:
        return _WA_BINARY
    return -1


def _build_col_encoders(
    batch: RecordBatch, schema: Schema, strict_mode: Bool
) raises -> Slab[_ColEncoder]:
    """Validate + build the per-column encoder list ONCE.

    Resolves each column's write tag and fetches its typed Arrow array a single
    time (one copy per column for the whole file). Raises (strict-mode) on the
    first unsupported Arrow type so no partial OCF is emitted.

    Returns a `Slab` (not `List`) because `_ColEncoder` holds Movable-only
    Arrow arrays — `List[T]` requires `T: Copyable`, `Slab[T]` requires only
    Movable."""
    var encoders = Slab[_ColEncoder]()
    var n = schema.num_columns()
    for c in range(n):
        var at = schema.field_arrow_type(c)
        var tag = _resolve_write_tag(at)
        if tag < 0:
            raise Error(
                String("AvroWriteError.UNSUPPORTED_TYPE: column ")
                + schema.field_name(c)
                + " has Arrow type "
                + String(at)
                + " which the Avro writer cannot encode (supported: flat"
                " primitives + int/long-backed arrow.* logicals; FIXED-backed"
                " uint64/float16, nested, decimal, enum write are not supported yet)"
            )
        var enc = _ColEncoder(tag, schema.field_nullable(c))
        # Fetch the typed array ONCE (not a per-cell deep copy).
        if tag == _WA_INT32:
            enc.i32 = batch.column_as_primitive_int32(c)
        elif tag == _WA_INT8:
            enc.i8 = batch.column_at(c).as_primitive[DType.int8]()
        elif tag == _WA_INT16:
            enc.i16 = batch.column_at(c).as_primitive[DType.int16]()
        elif tag == _WA_UINT8:
            enc.u8 = batch.column_at(c).as_primitive[DType.uint8]()
        elif tag == _WA_UINT16:
            enc.u16 = batch.column_at(c).as_primitive[DType.uint16]()
        elif tag == _WA_INT64:
            enc.i64 = batch.column_as_primitive_int64(c)
        elif tag == _WA_UINT32:
            enc.u32 = batch.column_at(c).as_primitive[DType.uint32]()
        elif tag == _WA_FLOAT32:
            enc.f32 = batch.column_as_primitive_float32(c)
        elif tag == _WA_FLOAT64:
            enc.f64 = batch.column_as_primitive_float64(c)
        elif tag == _WA_BOOL:
            enc.b = batch.column_as_boolean(c)
        elif tag == _WA_LARGE_STRING:
            # ⛔ NOT `column_as_string`: its int64 path narrows, and narrowing
            # is refused above the int32 ceiling — i.e. it refuses exactly the
            # column whose size caused the promotion.
            enc.ls = batch.column_as_large_string(c)
        else:  # _WA_STRING / _WA_BINARY both use the string accessor.
            enc.s = batch.column_as_string(c)
        encoders.append(enc^)
    _ = strict_mode
    return encoders^


# =============================================================================
# Column-major value encode.
# =============================================================================
#
# Each `_encode_col_*` function owns one column's whole-block encode: it takes
# the pre-resolved `_ColEncoder` (typed array already fetched ONCE) plus the
# [row0, row1) row span for the current block, and encodes that column's values
# for those rows into the per-(row, col) interleaved block payload via a
# striding write. Because OCF records interleave fields per row, the block
# payload is NOT a simple column-major concat — each column's bytes for a given
# row must land at that row's record position. We achieve "dispatch hoisted out
# of the inner loop" differently: `_encode_block` dispatches ONCE per column
# (on the integer tag) into a monomorphic per-column row loop, so the inner loop
# over rows is a single tight, inlinable encoder with no per-cell branch.
#
# To preserve record interleaving with a per-column inner loop, the block is
# encoded row-major at the OUTER level but the type dispatch is resolved per
# column up front. Concretely `_encode_block` loops rows × cols and calls
# `_encode_one_cell(enc, row, out)` which switches on `enc.tag` (a single Int
# compare chain the compiler lowers to a jump table) over the ALREADY-FETCHED
# array — O(1) per cell, no column copy, no ArrowType cascade.


@always_inline
def _emit_null_tag(nullable: Bool, is_null: Bool, mut out: List[UInt8]) -> Bool:
    """For a nullable column write the NULL_FIRST union tag; return True iff the
    cell is null (caller stops). No-op (returns False) for a non-nullable
    column."""
    if nullable:
        if is_null:
            encode_union_tag(0, out)  # null branch
            return True
        encode_union_tag(1, out)  # value branch
    return False


def _encode_one_cell(
    enc: _ColEncoder, row: Int, mut out: List[UInt8]
) raises:
    """Encode ONE cell using the pre-resolved encoder. Dispatches on the
    integer `tag` over the array fetched ONCE in `_build_col_encoders` — no
    per-cell column copy and, for strings, a zero-copy span."""
    var tag = enc.tag
    if tag == _WA_INT32:
        ref arr = enc.i32.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(arr.get(row), out)
    elif tag == _WA_INT64:
        ref arr = enc.i64.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_long(arr.get(row), out)
    elif tag == _WA_FLOAT64:
        ref arr = enc.f64.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_double(arr.get(row), out)
    elif tag == _WA_FLOAT32:
        ref arr = enc.f32.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_float(arr.get(row), out)
    elif tag == _WA_STRING:
        ref arr = enc.s.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        # Zero-copy span into the Arrow data buffer — no owned-String alloc.
        encode_bytes(arr.get_span(row), out)
    elif tag == _WA_LARGE_STRING:
        ref arr = enc.ls.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        # `LargeStringArray.get_span` is the int64-offset twin of the span
        # above and is the ONLY allocation-free way to walk a promoted
        # column — a `get()` per row on a 2 GiB+ column aborts.
        # Same `encode_bytes`, same wire bytes.
        encode_bytes(arr.get_span(row), out)
    elif tag == _WA_BINARY:
        ref arr = enc.s.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_bytes(arr.get_span(row), out)
    elif tag == _WA_BOOL:
        ref arr = enc.b.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_boolean(arr.get(row), out)
    elif tag == _WA_INT8:
        ref arr = enc.i8.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    elif tag == _WA_INT16:
        ref arr = enc.i16.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    elif tag == _WA_UINT8:
        ref arr = enc.u8.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    elif tag == _WA_UINT16:
        ref arr = enc.u16.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    else:  # _WA_UINT32 -> Avro long.
        ref arr = enc.u32.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_long(Int64(Int(arr.get(row))), out)
