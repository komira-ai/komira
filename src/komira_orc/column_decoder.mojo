# =============================================================================
# column_decoder.mojo — ORC per-column decode -> Arrow Column.
# =============================================================================
#
# This is the runtime-primary decode path: for each projected column the reader
# resolves the column's streams (PRESENT / DATA / LENGTH / DICTIONARY_DATA /
# SECONDARY) from the StripeFooter, then dispatches on `(Type.Kind,
# ColumnEncoding)` through a runtime tagged-union (Int8-tag if/elif — NO
# byte-erased fn-ptr, the same as the Avro reader) into a direct-to-Arrow
# column accumulator. NO `ColumnVectorBatch` intermediate.
#
# A `ColumnAcc` tagged-union accumulates decoded values + per-row validity
# ACROSS all stripes (multi-stripe files append into the same accumulator), so
# the whole file produces ONE Arrow Column per output column with no batch
# concatenation needed (mirrors the Avro reader's accumulator).
#
# Primitive coverage:
#   BOOLEAN / TINYINT / SMALLINT / INT / BIGINT / DATE / FLOAT / DOUBLE /
#   STRING (DIRECT + DICTIONARY) / BINARY.
# Compound types (LIST/MAP/STRUCT/UNION) decode in nested_decoder.mojo.
#
# Null handling: the PRESENT stream (boolean RLE) is the per-column validity
# bitmap (one bool per ROW). ORC's DATA/LENGTH streams hold values ONLY for
# non-null rows, so the decoder INTERLEAVES: walk per-row present flags, pull a
# decoded value from the dense list for each present row, push a null marker
# otherwise. No PRESENT stream => all rows present.
#
# Encapsulation: the decoder consumes borrowed/owned byte buffers and produces
# an owned Arrow Column. No UnsafePointer crosses the module boundary.
# =============================================================================

from std.sys.info import simd_width_of
from std.memory import unsafe_memcpy, unsafe_memset
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.string_builder import ArrowStringBuilder

from .footer import (
    ORC_STREAM_PRESENT,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
    ORC_STREAM_DICTIONARY_DATA,
    ORC_ENCODING_DIRECT_V2,
    ORC_ENCODING_DICTIONARY,
    ORC_ENCODING_DICTIONARY_V2,
)
from .orc_schema import (
    ORC_KIND_BOOLEAN,
    ORC_KIND_BYTE,
    ORC_KIND_SHORT,
    ORC_KIND_INT,
    ORC_KIND_LONG,
    ORC_KIND_FLOAT,
    ORC_KIND_DOUBLE,
    ORC_KIND_STRING,
    ORC_KIND_BINARY,
    ORC_KIND_DATE,
    ORC_KIND_VARCHAR,
    ORC_KIND_CHAR,
    orc_kind_name,
)
from .rle_decode import (
    decode_int_rle,
    decode_int_rle_into,
    decode_int_rle_into_span,
    decode_boolean_rle,
    decode_byte_rle,
)


# =============================================================================
# StreamSpan — a decompressed stream's raw bytes + its kind, for one column.
# =============================================================================


@fieldwise_init
struct StreamSpan(Copyable, Movable):
    """One decompressed stream for a column: its kind + its raw bytes."""

    var kind: Int
    var bytes: List[UInt8]


def _find_stream(streams: List[StreamSpan], kind: Int) raises -> Int:
    for i in range(len(streams)):
        if streams[i].kind == kind:
            return i
    return -1


# =============================================================================
# Untrusted-scalar ceilings. See ColumnAcc.reserve for why.
# =============================================================================
#
# `ORC_MAX_ROWS` bounds any DECLARED row count before it is multiplied by an
# element width to size an allocation. 2^40 rows is a trillion — orders of
# magnitude beyond anything this reader will materialize into RAM as one
# RecordBatch — and `2^40 * 8` is 2^43, nowhere near the Int64 overflow that
# would make `total_rows * 8` wrap to ZERO.

comptime ORC_MAX_ROWS: Int = 1 << 40


# =============================================================================
# Accumulator-kind tags (Int8 tagged-union; NO byte-erased fn-ptr).
# =============================================================================

comptime ACC_BOOL: Int8 = 0
comptime ACC_I8: Int8 = 1
comptime ACC_I16: Int8 = 2
comptime ACC_I32: Int8 = 3
comptime ACC_I64: Int8 = 4
comptime ACC_F32: Int8 = 5
comptime ACC_F64: Int8 = 6
comptime ACC_STRING: Int8 = 7
comptime ACC_BINARY: Int8 = 8


# =============================================================================
# ColumnAcc — per-output-column accumulator across all stripes.
# =============================================================================
#
# Holds the dense value lists for whichever variant the column maps to, plus a
# per-row present-flag list (the validity bitmap source). Only the active
# variant's list is non-empty. `build()` emits one Arrow Column.


struct ColumnAcc(Movable):
    var tag: Int8
    var arrow_type: ArrowType
    var present: List[Bool]
    var i64s: List[Int64]  # i8/i16/i32/i64/bool/date all funnel through here
    var f32s: List[Float32]
    var f64s: List[Float64]
    var string_builder: ArrowStringBuilder
    var binaries: List[List[UInt8]]
    # For the ACC_I64 (BIGINT) no-null path, decode straight into
    # this 64B-aligned Arrow buffer instead of the `i64s` List. `_build_int64`
    # then MOVES this buffer into the PrimitiveArray with ZERO copy (vs the
    # whole-column `_bulk_fill_int` re-copy the List path requires). The
    # buffer is sized once in `reserve(total_rows)`. Active only when
    # `i64_buf_active` is True (ACC_I64 + total_rows known + no-null so far);
    # the nullable/cast paths still funnel through `i64s`.
    var i64_buf: OwnedAlignedBuffer
    var i64_buf_active: Bool
    # Row count + nullability flag track the column WITHOUT
    # materializing/scanning `present` on the no-null fast path. liborc holds
    # the equivalent in a single `hasNulls` bool + a row counter; a
    # `len(present)` + `_null_count()` full scan would cost one wasted
    # iteration per row per non-nullable column. `n_rows` is the total
    # row count appended across all stripes (always tracked); `present` is only
    # materialized on the nullable slow path (where `has_any_nulls` flips True).
    var n_rows: Int
    var has_any_nulls: Bool

    def __init__(out self, tag: Int8, arrow_type: ArrowType):
        self.tag = tag
        self.arrow_type = arrow_type
        self.present = List[Bool]()
        self.i64s = List[Int64]()
        self.f32s = List[Float32]()
        self.f64s = List[Float64]()
        self.string_builder = ArrowStringBuilder()
        self.binaries = List[List[UInt8]]()
        self.i64_buf = OwnedAlignedBuffer(0)
        self.i64_buf_active = False
        self.n_rows = 0
        self.has_any_nulls = False

    @always_inline
    def _null_count(self) raises -> Int:
        # No-null columns return 0 in O(1) — liborc pays one
        # `test hasNulls` per stripe, not a full-column scan per build call.
        # When `has_any_nulls` is set, `present` must hold one flag per row;
        # the builds index it by row, so a short list is refused here.
        if not self.has_any_nulls:
            return 0
        if len(self.present) != self.n_rows:
            raise Error(
                String("OrcDecodeError.INTERNAL: the column has ")
                + String(self.n_rows)
                + " rows but "
                + String(len(self.present))
                + " validity flags"
            )
        var c = 0
        for i in range(len(self.present)):
            if not self.present[i]:
                c += 1
        return c

    def reserve(mut self, total_rows: Int) raises:
        """Pre-size the accumulator's active inner list(s) + present list to
        `total_rows`.

        Why: a multi-stripe file accumulates into `acc.i64s` / `acc.present`
        across all stripes via `List.append`. With the default doubling
        growth strategy, the geometric reallocation cascade
        (`List._realloc` -> memmove) dominates the decode of a wide,
        many-stripe file.

        Pre-reserving once to the known total row count from the file Footer
        eliminates ALL intermediate reallocations: each stripe's `append`
        becomes a pure pointer-bump.

        Cost: zero for cold (we'd allocate the buffer once anyway); the win
        is avoiding log2(stripes) memmoves of the full prefix — several times
        the column's size in redundant copies, per column.

        Variant-dispatch: only the ACTIVE inner-list for the column's tag is
        reserved (we never touch the other variants).

        `present` is NOT reserved up-front. Non-nullable columns never
        materialize `present` at all (the no-null fast paths and the
        `n_present == n` slow-path branch skip it), so a full-length reserve
        per column would be pure waste. The rare nullable column lazily reserves `present` via
        `_ensure_present_synced` -> `_append_n_true` (resize) on first null.

        ⚠ `total_rows` IS `Footer.numberOfRows` — a protobuf uint64 the file's
        writer chose. Two distinct breaks are possible here:

          1. `total_rows * 8` (the ACC_I64 arm) WRAPS. `(1 << 61) * 8 == 0` in
             Mojo, so a footer declaring 2^61 rows would allocate a ZERO-byte
             Arrow buffer and still set `i64_buf_active = True` — leaving the
             zero-copy decode path enabled and pointed at nothing.
          2. Nothing relates `total_rows` to the bytes actually present.

        Both are closed by ONE check at the head of this function — the only
        place a row count becomes an allocation. Callers additionally
        cross-check `total_rows` against the file length before getting here
        (`orc_reader._checked_total_rows`); this bound is the type-level one
        that holds no matter who calls.
        """
        if total_rows < 0:
            raise Error(
                String("OrcDecodeError.BAD_ROW_COUNT: negative row count ")
                + String(total_rows)
            )
        if total_rows > ORC_MAX_ROWS:
            raise Error(
                String("OrcDecodeError.BAD_ROW_COUNT: declared row count ")
                + String(total_rows)
                + " exceeds the maximum "
                + String(ORC_MAX_ROWS)
                + " (its byte size would overflow and silently allocate a"
                " short buffer)"
            )
        if self.tag == ACC_BOOL:
            self.i64s.reserve(total_rows)
        elif self.tag == ACC_I8:
            self.i64s.reserve(total_rows)
        elif self.tag == ACC_I16:
            self.i64s.reserve(total_rows)
        elif self.tag == ACC_I32:
            self.i64s.reserve(total_rows)
        elif self.tag == ACC_I64:
            # Pre-allocate the 64B-aligned Arrow output buffer to
            # the full row count and decode straight into it (no `i64s` List,
            # no build-time copy). `i64_buf_active` gates the zero-copy path;
            # if any stripe takes the nullable slow path, it falls back to
            # `i64s` (see `_decode_int_into`).
            if total_rows > 0:
                self.i64_buf = OwnedAlignedBuffer(total_rows * 8)
                self.i64_buf_active = True
            else:
                self.i64s.reserve(total_rows)
        elif self.tag == ACC_F32:
            self.f32s.reserve(total_rows)
        elif self.tag == ACC_F64:
            self.f64s.reserve(total_rows)
        elif self.tag == ACC_STRING:
            # String validity is tracked inside the builder, NOT acc.present;
            # reserve the builder's offset list instead of acc.present below.
            self.string_builder.reserve_rows(total_rows)
        elif self.tag == ACC_BINARY:
            self.binaries.reserve(total_rows)

    def build(var self) raises -> Column[HeapRegion]:
        if self.tag == ACC_BOOL:
            return self^._build_bool()
        elif self.tag == ACC_I8:
            return self^._build_int[DType.int8, ArrowType.INT8]()
        elif self.tag == ACC_I16:
            return self^._build_int[DType.int16, ArrowType.INT16]()
        elif self.tag == ACC_I32:
            return self^._build_int32()
        elif self.tag == ACC_I64:
            return self^._build_int64()
        elif self.tag == ACC_F32:
            return self^._build_f32()
        elif self.tag == ACC_F64:
            return self^._build_f64()
        elif self.tag == ACC_STRING:
            return self^._build_string()
        elif self.tag == ACC_BINARY:
            return self^._build_binary()
        raise Error("OrcDecodeError.INTERNAL: unknown accumulator tag")

    def _build_bool(var self) raises -> Column[HeapRegion]:
        var n = self.n_rows
        var nc = self._null_count()
        var arr = BooleanArray.allocate(n)
        for i in range(n):
            arr.set(i, self.i64s[i] != 0)
        if nc > 0:
            for i in range(n):
                if not self.present[i]:
                    arr._set_null(i)
        return Column.from_boolean(arr)

    def _build_int[
        dt: DType, at: ArrowType
    ](var self) raises -> Column[HeapRegion]:
        var n = self.n_rows
        var nc = self._null_count()
        if nc == 0:
            var arr = PrimitiveArray[dt].allocate(n)
            _bulk_fill_int[dt](arr, self.i64s)
            return Column.from_primitive_with_arrow_type[dt](arr, at)
        var arr = PrimitiveArray[dt].allocate_nullable(n)
        _bulk_fill_int[dt](arr, self.i64s)
        _apply_present_nulls[dt](arr, self.present, nc)
        return Column.from_primitive_with_arrow_type[dt](arr, at)

    def _build_int32(var self) raises -> Column[HeapRegion]:
        var n = self.n_rows
        var nc = self._null_count()
        if nc == 0:
            var arr = PrimitiveArray[DType.int32].allocate(n)
            _bulk_fill_int[DType.int32](arr, self.i64s)
            return Column.from_primitive_with_arrow_type[DType.int32](
                arr, self.arrow_type
            )
        var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
        _bulk_fill_int[DType.int32](arr, self.i64s)
        _apply_present_nulls[DType.int32](arr, self.present, nc)
        return Column.from_primitive_with_arrow_type[DType.int32](
            arr, self.arrow_type
        )

    def _build_int64(var self) raises -> Column[HeapRegion]:
        var n = self.n_rows
        var nc = self._null_count()
        if nc == 0:
            if self.i64_buf_active:
                # The values were decoded straight into the
                # 64B-aligned Arrow buffer — MOVE it into the PrimitiveArray
                # with zero copy (no allocate, no `_bulk_fill_int` pass).
                self.i64_buf.set_length(Int64(n * 8))

                var buf = OwnedAlignedBuffer(0)
                swap(self.i64_buf, buf)
                var arr = PrimitiveArray[DType.int64](
                    buf^, n, None, 0, 0
                )
                return Column.from_primitive_with_arrow_type[DType.int64](
                    arr, self.arrow_type
                )
            var arr = PrimitiveArray[DType.int64].allocate(n)
            _bulk_fill_int[DType.int64](arr, self.i64s)
            return Column.from_primitive_with_arrow_type[DType.int64](
                arr, self.arrow_type
            )
        var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
        _bulk_fill_int[DType.int64](arr, self.i64s)
        _apply_present_nulls[DType.int64](arr, self.present, nc)
        return Column.from_primitive_with_arrow_type[DType.int64](
            arr, self.arrow_type
        )

    def _build_f32(var self) raises -> Column[HeapRegion]:
        var n = self.n_rows
        var nc = self._null_count()
        if nc == 0:
            var arr = PrimitiveArray[DType.float32].allocate(n)
            _bulk_fill_same[DType.float32](arr, self.f32s)
            return Column.from_primitive[DType.float32](arr)
        var arr = PrimitiveArray[DType.float32].allocate_nullable(n)
        _bulk_fill_same[DType.float32](arr, self.f32s)
        _apply_present_nulls[DType.float32](arr, self.present, nc)
        return Column.from_primitive[DType.float32](arr)

    def _build_f64(var self) raises -> Column[HeapRegion]:
        var n = self.n_rows
        var nc = self._null_count()
        if nc == 0:
            var arr = PrimitiveArray[DType.float64].allocate(n)
            _bulk_fill_same[DType.float64](arr, self.f64s)
            return Column.from_primitive[DType.float64](arr)
        var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
        _bulk_fill_same[DType.float64](arr, self.f64s)
        _apply_present_nulls[DType.float64](arr, self.present, nc)
        return Column.from_primitive[DType.float64](arr)

    def _build_string(var self) raises -> Column[HeapRegion]:
        # The builder accumulated values straight into Arrow (offsets, data)
        # layout and tracked its own validity — no List[String] intermediate,
        # no from_strings re-serialize pass. build() does ONE memcpy each.
        #
        # Swap the builder out of `self` (leaving an empty, destructor-safe
        # builder in its place) rather than partial-moving the field with `^`,
        # which would leave `self` un-droppable (a partial move).
        var builder = ArrowStringBuilder()
        swap(self.string_builder, builder)
        return builder^.build()

    def _build_binary(var self) raises -> Column[HeapRegion]:
        var nc = self._null_count()
        var arr = BinaryArray.from_bytes_list(self.binaries)
        if nc > 0:
            var bm = _bitmap_from_present(self.present)
            arr.validity = bm^
            arr.null_count = nc
        return Column.from_binary(arr)


def _bitmap_from_present(present: List[Bool]) raises -> Bitmap[HeapRegion]:
    """Validity bitmap (bit i == 1 iff row i is VALID/present)."""
    var bm = Bitmap.create_all_valid(len(present))
    for i in range(len(present)):
        if not present[i]:
            bm.clear(i)
    return bm^


# =============================================================================
# Accumulator factory — pick the variant for an ORC Type.Kind.
# =============================================================================


def make_accumulator(kind: Int, arrow_type: ArrowType) raises -> ColumnAcc:
    if kind == ORC_KIND_BOOLEAN:
        return ColumnAcc(ACC_BOOL, arrow_type)
    elif kind == ORC_KIND_BYTE:
        return ColumnAcc(ACC_I8, arrow_type)
    elif kind == ORC_KIND_SHORT:
        return ColumnAcc(ACC_I16, arrow_type)
    elif kind == ORC_KIND_INT or kind == ORC_KIND_DATE:
        return ColumnAcc(ACC_I32, arrow_type)
    elif kind == ORC_KIND_LONG:
        return ColumnAcc(ACC_I64, arrow_type)
    elif kind == ORC_KIND_FLOAT:
        return ColumnAcc(ACC_F32, arrow_type)
    elif kind == ORC_KIND_DOUBLE:
        return ColumnAcc(ACC_F64, arrow_type)
    elif (
        kind == ORC_KIND_STRING
        or kind == ORC_KIND_VARCHAR
        or kind == ORC_KIND_CHAR
    ):
        return ColumnAcc(ACC_STRING, arrow_type)
    elif kind == ORC_KIND_BINARY:
        return ColumnAcc(ACC_BINARY, arrow_type)
    raise Error(
        String("OrcDecodeError.UNSUPPORTED_TYPE: ORC Type.Kind ")
        + orc_kind_name(kind)
        + " ("
        + String(kind)
        + ") is not a primitive kind this decoder handles (nested types use the"
        " nested decoder; decimal / timestamp are not supported)"
    )


# =============================================================================
# decode_stripe_column — decode one stripe's worth of a column INTO an acc.
# =============================================================================


def decode_stripe_column(
    mut acc: ColumnAcc,
    kind: Int,
    encoding_kind: Int,
    dict_size: Int,
    streams: List[StreamSpan],
    n_rows: Int,
) raises:
    """Append one stripe's decoded values for a column into `acc`.

    Fast-path: when the column has NO PRESENT stream in this stripe, every row is implicitly
    present. The fast-path skips BOTH `_decode_present` (which would
    materialize a length-n_rows `List[Bool]` of all-True) AND
    `_count_true` (which would walk that bool list), then dispatches to
    a `_no_present_*_into` variant per type that bulk-extends the
    accumulator without per-row interleave branching.

    A wide, many-stripe, all-non-nullable file is the canonical hit: there
    `decode_stripe_column` would otherwise spend its time in per-row
    interleave loops that are pure overhead when n_present == n_rows.
    """
    var is_v2 = (
        encoding_kind == ORC_ENCODING_DIRECT_V2
        or encoding_kind == ORC_ENCODING_DICTIONARY_V2
    )
    var is_dict = (
        encoding_kind == ORC_ENCODING_DICTIONARY
        or encoding_kind == ORC_ENCODING_DICTIONARY_V2
    )
    # The ORC v1 spec ("Column Encoding") allows DICTIONARY / DICTIONARY_V2
    # only on STRING, VARCHAR and CHAR. Any other kind would be decoded as
    # DIRECT, which reads the wrong streams, so it is refused.
    if is_dict and not (
        kind == ORC_KIND_STRING
        or kind == ORC_KIND_VARCHAR
        or kind == ORC_KIND_CHAR
    ):
        raise Error(
            String("OrcDecodeError.BAD_ENCODING: ORC Type.Kind ")
            + orc_kind_name(kind)
            + " has a DICTIONARY encoding ("
            + String(encoding_kind)
            + "); the ORC spec allows dictionary encoding only on string kinds"
        )

    # Fast-path detection: ORC's PRESENT stream is OPTIONAL per column per
    # stripe (ORC spec). Its absence means every row
    # is present; we can bypass the per-row interleave entirely.
    var has_present = _has_present_stream(streams)

    if not has_present:
        # No-null bulk fast-path for each primitive type.
        if kind == ORC_KIND_BOOLEAN:
            _no_present_boolean_into(acc, streams, n_rows)
        elif kind == ORC_KIND_BYTE:
            _no_present_tinyint_into(acc, streams, n_rows)
        elif (
            kind == ORC_KIND_SHORT
            or kind == ORC_KIND_INT
            or kind == ORC_KIND_LONG
            or kind == ORC_KIND_DATE
        ):
            _no_present_int_into(acc, streams, n_rows, is_v2)
        elif kind == ORC_KIND_FLOAT:
            _no_present_float32_into(acc, streams, n_rows)
        elif kind == ORC_KIND_DOUBLE:
            _no_present_float64_into(acc, streams, n_rows)
        elif (
            kind == ORC_KIND_STRING
            or kind == ORC_KIND_VARCHAR
            or kind == ORC_KIND_CHAR
        ):
            if is_dict:
                _no_present_string_dict_into(
                    acc, streams, n_rows, is_v2, dict_size
                )
            else:
                _no_present_string_direct_into(acc, streams, n_rows, is_v2)
        elif kind == ORC_KIND_BINARY:
            _no_present_binary_into(acc, streams, n_rows, is_v2)
        else:
            raise Error(
                String("OrcDecodeError.UNSUPPORTED_TYPE: ORC Type.Kind ")
                + orc_kind_name(kind)
                + " is not a primitive kind this decoder handles"
            )
        # The fast paths do not touch `acc.present`. Once an earlier stripe
        # had a null, `present` holds one flag per row so far and must grow
        # by this stripe's rows too, or a later stripe's flags land on the
        # wrong rows (ORC writers omit PRESENT for a stripe with no nulls).
        # STRING keeps validity in its builder and never sets `has_any_nulls`.
        if acc.has_any_nulls:
            _append_n_true(acc.present, n_rows)
        return

    # Slow-path (nullable): some rows are null; need full PRESENT walk.
    var present = _decode_present(streams, n_rows)
    var n_present = _count_true(present)

    if kind == ORC_KIND_BOOLEAN:
        _decode_boolean_into(acc, streams, present, n_present)
    elif kind == ORC_KIND_BYTE:
        _decode_tinyint_into(acc, streams, present, n_present)
    elif (
        kind == ORC_KIND_SHORT
        or kind == ORC_KIND_INT
        or kind == ORC_KIND_LONG
        or kind == ORC_KIND_DATE
    ):
        _decode_int_into(acc, streams, present, n_present, is_v2)
    elif kind == ORC_KIND_FLOAT:
        _decode_float32_into(acc, streams, present)
    elif kind == ORC_KIND_DOUBLE:
        _decode_float64_into(acc, streams, present)
    elif (
        kind == ORC_KIND_STRING
        or kind == ORC_KIND_VARCHAR
        or kind == ORC_KIND_CHAR
    ):
        if is_dict:
            _decode_string_dict_into(
                acc, streams, present, n_present, is_v2, dict_size
            )
        else:
            _decode_string_direct_into(acc, streams, present, n_present, is_v2)
    elif kind == ORC_KIND_BINARY:
        _decode_binary_into(acc, streams, present, n_present, is_v2)
    else:
        raise Error(
            String("OrcDecodeError.UNSUPPORTED_TYPE: ORC Type.Kind ")
            + orc_kind_name(kind)
            + " is not a primitive kind this decoder handles"
        )


# =============================================================================
# Present-stream helpers.
# =============================================================================


def _decode_present(streams: List[StreamSpan], n_rows: Int) raises -> List[Bool]:
    var idx = _find_stream(streams, ORC_STREAM_PRESENT)
    if idx < 0:
        var out = List[Bool]()
        for _i in range(n_rows):
            out.append(True)
        return out^
    return decode_boolean_rle(streams[idx].bytes, n_rows)


@always_inline
def _count_true(present: List[Bool]) -> Int:
    var c = 0
    for i in range(len(present)):
        if present[i]:
            c += 1
    return c


@always_inline
def _has_present_stream(streams: List[StreamSpan]) -> Bool:
    """True iff the column has a PRESENT stream in this stripe.

    Fast O(n_streams) scan — n_streams is tiny (typically 2-4). Cheaper
    than `_decode_present` + `_count_true` by one list op per row per
    column. See the `decode_stripe_column` docstring.
    """
    for i in range(len(streams)):
        if streams[i].kind == ORC_STREAM_PRESENT:
            return True
    return False


# =============================================================================
# Per-type decode-into-accumulator bodies.
# =============================================================================


def _decode_boolean_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    present: List[Bool],
    n_present: Int,
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: BOOLEAN has no DATA")
    var vals = decode_boolean_rle(streams[didx].bytes, n_present)
    var n = len(present)
    var prior = acc.n_rows
    acc.n_rows += n
    if n_present != n:
        _ensure_present_synced(acc, prior)
    var track_present = acc.has_any_nulls
    var vi = 0
    for i in range(n):
        if track_present:
            acc.present.append(present[i])
        if present[i]:
            acc.i64s.append(Int64(1) if vals[vi] else Int64(0))
            vi += 1
        else:
            acc.i64s.append(Int64(0))


def _decode_tinyint_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    present: List[Bool],
    n_present: Int,
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: TINYINT has no DATA")
    var raw = decode_byte_rle(streams[didx].bytes, n_present)
    var n = len(present)
    var prior = acc.n_rows
    acc.n_rows += n
    if n_present != n:
        _ensure_present_synced(acc, prior)
    var track_present = acc.has_any_nulls
    var vi = 0
    for i in range(n):
        if track_present:
            acc.present.append(present[i])
        if present[i]:
            var b = Int(raw[vi])
            if b >= 128:
                b -= 256
            acc.i64s.append(Int64(b))
            vi += 1
        else:
            acc.i64s.append(Int64(0))


@always_inline
def _ensure_present_synced(mut acc: ColumnAcc, prior_rows: Int):
    """Lazily materialize `acc.present` the first time a NULL-bearing stripe
    is seen on a nullable-capable path.

    Until the first null is observed, `acc.present` stays empty even though
    `prior_rows` rows have been appended (all implicitly present). This helper
    backfills `present` with `prior_rows` True flags and flips
    `has_any_nulls`, so the caller's subsequent per-row present appends keep
    `present` in lock-step with the value lists. Idempotent: a no-op once
    `has_any_nulls` is set.

    `prior_rows` = the number of rows appended BEFORE this stripe (i.e. the
    accumulator row count minus this stripe's row count). The caller invokes
    this BEFORE appending this stripe's own present flags.

    Why: the common case (fully non-nullable columns) never calls this — the
    nullable slow path's `n_present == n` branch skips it. Only a column that
    actually contains a null in some stripe pays the one-time backfill, and
    only for the rows decoded before that first null-bearing stripe.
    """
    if acc.has_any_nulls:
        return
    acc.has_any_nulls = True
    if prior_rows > 0:
        _append_n_true(acc.present, prior_rows)


def _i64_buf_fallback_to_list(mut acc: ColumnAcc):
    """A nullable stripe was seen on an ACC_I64 column
    that had been decoding zero-copy into `i64_buf`. Migrate the rows decoded
    so far (`acc.n_rows`, set BEFORE this stripe is appended) from the aligned
    buffer into the `i64s` List and deactivate the buffer path, so the rest of
    the column (and the build) use the validity-aware List path.

    This is the rare case (a BIGINT column with a null in some stripe). The
    common all-non-nullable BIGINT column never calls this.
    """
    if not acc.i64_buf_active:
        return
    var prior = acc.n_rows
    acc.i64s.reserve(prior)
    # SAFETY: `i64_buf` holds `prior` valid Int64 values [0, prior); read them
    # back through a typed accessor (bounds-checked) and append to `i64s`.
    for i in range(prior):
        acc.i64s.append(acc.i64_buf.get_typed[Int64](i))
    acc.i64_buf_active = False
    var empty = OwnedAlignedBuffer(0)
    swap(acc.i64_buf, empty)


def _decode_int_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    present: List[Bool],
    n_present: Int,
    is_v2: Bool,
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: integer column has no DATA")
    var n = len(present)
    if n_present == n:
        # No-null fast path: decode RLE DIRECTLY into the accumulator's
        # dense list — no intermediate `vals` list, no copy pass (there is no
        # `vals` to copy from at all). Every row is present so decoded order IS column order.
        # This stripe has no nulls. If NO prior stripe in this
        # column ever had a null (`has_any_nulls == False`), do NOT touch
        # `acc.present` at all — it stays lazily empty. If a PRIOR stripe
        # already flipped `has_any_nulls`, we must keep `present` in lock-step,
        # so append n True flags (one bulk memset, not a per-row loop).
        if acc.has_any_nulls:
            _append_n_true(acc.present, n)
        # ACC_I64 all-present stripe -> decode into the aligned
        # Arrow buffer (zero-copy) when still active.
        if acc.i64_buf_active:
            var elem_start = acc.n_rows
            acc.n_rows += n
            decode_int_rle_into_span(
                streams[didx].bytes,
                n_present,
                True,
                is_v2,
                acc.i64_buf.into_span_capacity(),
                elem_start,
            )
            return
        acc.i64s.reserve(len(acc.i64s) + n)
        acc.n_rows += n
        decode_int_rle_into(
            streams[didx].bytes, n_present, True, is_v2, acc.i64s
        )
        return
    # Null-bearing stripe: migrate any zero-copy buffer rows to the List path,
    # then decode interleaved with validity.
    _i64_buf_fallback_to_list(acc)
    acc.i64s.reserve(len(acc.i64s) + n)
    _ensure_present_synced(acc, acc.n_rows)
    acc.n_rows += n
    var vals = decode_int_rle(streams[didx].bytes, n_present, True, is_v2)
    var vi = 0
    for i in range(n):
        acc.present.append(present[i])
        if present[i]:
            acc.i64s.append(vals[vi])
            vi += 1
        else:
            acc.i64s.append(Int64(0))


def _decode_float32_into(
    mut acc: ColumnAcc, streams: List[StreamSpan], present: List[Bool]
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: FLOAT has no DATA")
    ref data = streams[didx].bytes
    var n = len(present)
    var n_present = _count_true(present)
    var prior = acc.n_rows
    acc.n_rows += n
    acc.f32s.reserve(len(acc.f32s) + n)
    if n_present == n:
        # No-null fast path: ORC FLOAT DATA is contiguous little-endian
        # IEEE-754 = native f32 layout — bulk-copy 4 bytes/value.
        if 4 * n > len(data):
            raise Error("OrcDecodeError.TRUNCATED: FLOAT data overrun")
        # Only maintain `present` if a prior stripe had nulls.
        if acc.has_any_nulls:
            _append_n_true(acc.present, n)
        var start = len(acc.f32s)
        acc.f32s.resize(unsafe_uninit_length=start + n)
        # SAFETY: dst pre-sized to start+n; src has >= 4*n bytes (checked);
        # memcpy is byte-exact + endian-correct on little-endian targets.
        unsafe_memcpy(
            dest=(acc.f32s.unsafe_ptr() + start).bitcast[UInt8](),
            src=data.unsafe_ptr(),
            count=4 * n,
        )
        return
    _ensure_present_synced(acc, prior)
    var bp = 0
    for i in range(n):
        acc.present.append(present[i])
        if present[i]:
            if bp + 4 > len(data):
                raise Error("OrcDecodeError.TRUNCATED: FLOAT data overrun")
            var u: UInt32 = 0
            for k in range(4):
                u |= UInt32(data[bp + k]) << UInt32(8 * k)
            acc.f32s.append(_u32_to_f32(u))
            bp += 4
        else:
            acc.f32s.append(Float32(0))


def _decode_float64_into(
    mut acc: ColumnAcc, streams: List[StreamSpan], present: List[Bool]
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: DOUBLE has no DATA")
    ref data = streams[didx].bytes
    var n = len(present)
    var n_present = _count_true(present)
    var prior = acc.n_rows
    acc.n_rows += n
    acc.f64s.reserve(len(acc.f64s) + n)
    if n_present == n:
        # No-null fast path: ORC DOUBLE DATA is contiguous little-endian
        # IEEE-754, which is the native f64 layout on x86_64/arm64 — bulk-copy
        # 8 bytes/value straight into the accumulator. No per-byte assembly.
        if 8 * n > len(data):
            raise Error("OrcDecodeError.TRUNCATED: DOUBLE data overrun")
        # Only maintain `present` if a prior stripe had nulls.
        if acc.has_any_nulls:
            _append_n_true(acc.present, n)
        var start = len(acc.f64s)
        acc.f64s.resize(unsafe_uninit_length=start + n)
        _bulk_copy_le_f64(data, acc.f64s, start, n)
        return
    _ensure_present_synced(acc, prior)
    var bp = 0
    for i in range(n):
        acc.present.append(present[i])
        if present[i]:
            if bp + 8 > len(data):
                raise Error("OrcDecodeError.TRUNCATED: DOUBLE data overrun")
            var u: UInt64 = 0
            for k in range(8):
                u |= UInt64(data[bp + k]) << UInt64(8 * k)
            acc.f64s.append(_u64_to_f64(u))
            bp += 8
        else:
            acc.f64s.append(Float64(0))


def _bulk_copy_le_f64(
    data: List[UInt8], mut out: List[Float64], start: Int, n: Int
) raises:
    """Bulk-copy `n` little-endian f64 values from `data` into `out[start:]`.

    # SAFETY: `src`/`dst` are concrete-origin views; bounds validated by caller
    # (8*n <= len(data); out pre-sized to start+n). memcpy is byte-exact and
    # endian-correct on little-endian targets (x86_64/arm64).
    """
    var src = data.unsafe_ptr()
    var dst = out.unsafe_ptr() + start
    unsafe_memcpy(
        dest=dst.bitcast[UInt8](),
        src=src,
        count=8 * n,
    )


def _decode_lengths(
    streams: List[StreamSpan], n_present: Int, is_v2: Bool
) raises -> List[Int64]:
    """Decode a STRING / BINARY / LIST / MAP LENGTH stream.

    ⚠ THE NON-NEGATIVITY CHECK BELONGS HERE, NOT AT THE USE SITES.

    LENGTH streams are decoded as UNSIGNED RLE (`signed=False`) into Int64, so a
    DIRECT run at bit-width 64 yields an ARBITRARY 64-bit pattern — including
    ones whose Int64 reading is negative. Every consumer's guard,
    `if off + ln > len(data): raise`, is passed trivially by a negative `ln`:

      * `_decode_string_direct_into` does `Span(data)[off : off + ln]` — an
        INVERTED range, i.e. a negative-length Span handed to
        `string_builder.push_bytes`.
      * `_decode_binary_into` / `_no_present_binary_into` do `off += ln`, which
        walks the read cursor BACKWARDS; once `off < -len(data)` the `data[k]`
        reads leave the List entirely.
      * `_no_present_string_direct_into` sums them into `total`, where huge
        and negative values CANCEL to an in-range total while the builder's
        per-value prefix-sum walks the offsets outside the copied block.

    Validating once here — ONE pass over an array we just materialized, on a
    path that already did far more work per element — makes those four sites
    correct by construction and keeps the check off the per-value copy loops.

    ⚠ THERE IS A FIFTH DECODER of a LENGTH stream, `_materialize_dict`, which
    calls `decode_int_rle` itself and therefore never passes through here. The
    check lives in the named helper `_check_lengths_non_negative` and BOTH
    decoders call it. If you add another LENGTH decoder, call that helper; do
    not re-inline the loop.
    """
    var lidx = _find_stream(streams, ORC_STREAM_LENGTH)
    if lidx < 0:
        raise Error("OrcDecodeError.MISSING_LENGTH: column has no LENGTH stream")
    var lens = decode_int_rle(streams[lidx].bytes, n_present, False, is_v2)
    _check_lengths_non_negative(lens)
    return lens^


def _check_lengths_non_negative(lens: List[Int64]) raises:
    """Reject a decoded LENGTH array containing a negative value.

    ⚠ A NAMED HELPER, NOT AN INLINE LOOP IN `_decode_lengths`, BECAUSE THERE IS
    A SECOND DECODER OF LENGTH STREAMS.

    `_materialize_dict` decodes the DICTIONARY column's LENGTH stream with its
    own `decode_int_rle(...)` call instead of going through `_decode_lengths`,
    so a guard inlined there would not reach it. Same stream kind, same
    `signed=False` Int64 decode, same DIRECT-at-width-64 run that sets the sign
    bit. Hoisting the check into a named helper is what makes "all the sites"
    checkable rather than asserted.

    The OR-accumulator is branchless: any negative value sets the sign bit of
    `sign_acc`, so ONE test at the end covers the whole array. This runs once
    per LENGTH stream over an array we just materialized, never per value copy.
    """
    var sign_acc: Int64 = 0
    for i in range(len(lens)):
        sign_acc |= lens[i]
    if sign_acc < 0:
        raise Error(
            "OrcDecodeError.NEGATIVE_LENGTH: the LENGTH stream decoded a"
            " negative value length (an unsigned RLE run wide enough to set the"
            " Int64 sign bit); a byte length cannot be negative"
        )


def _decode_string_direct_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    present: List[Bool],
    n_present: Int,
    is_v2: Bool,
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: STRING has no DATA")
    ref data = streams[didx].bytes
    var lens = _decode_lengths(streams, n_present, is_v2)
    # STRING tracks validity inside the builder, not `acc.present`; just bump
    # the row counter (used by the build path for the array length).
    acc.n_rows += len(present)
    var off = 0
    var vi = 0
    for i in range(len(present)):
        if present[i]:
            var ln = Int(lens[vi])
            vi += 1
            if off + ln > len(data):
                raise Error("OrcDecodeError.TRUNCATED: STRING data overrun")
            # Stream raw bytes straight into the Arrow (offsets, data)
            # builder — no per-value String alloc, no re-serialize at build.
            acc.string_builder.push_bytes(Span(data)[off : off + ln])
            off += ln
        else:
            acc.string_builder.push_null()


def _decode_binary_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    present: List[Bool],
    n_present: Int,
    is_v2: Bool,
) raises:
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: BINARY has no DATA")
    ref data = streams[didx].bytes
    var lens = _decode_lengths(streams, n_present, is_v2)
    var n = len(present)
    var prior = acc.n_rows
    acc.n_rows += n
    if n_present != n:
        _ensure_present_synced(acc, prior)
    var track_present = acc.has_any_nulls
    var off = 0
    var vi = 0
    for i in range(n):
        if track_present:
            acc.present.append(present[i])
        if present[i]:
            var ln = Int(lens[vi])
            vi += 1
            if off + ln > len(data):
                raise Error("OrcDecodeError.TRUNCATED: BINARY data overrun")
            var b = List[UInt8]()
            for k in range(off, off + ln):
                b.append(data[k])
            acc.binaries.append(b^)
            off += ln
        else:
            acc.binaries.append(List[UInt8]())


def _decode_string_dict_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    present: List[Bool],
    n_present: Int,
    is_v2: Bool,
    dict_size: Int,
) raises:
    var ddidx = _find_stream(streams, ORC_STREAM_DICTIONARY_DATA)
    if ddidx < 0:
        raise Error(
            "OrcDecodeError.MISSING_DICTIONARY_DATA: DICTIONARY STRING column"
        )
    ref dict_bytes = streams[ddidx].bytes
    var lidx = _find_stream(streams, ORC_STREAM_LENGTH)
    if lidx < 0:
        raise Error("OrcDecodeError.MISSING_LENGTH: DICTIONARY column LENGTH")
    # Dict materialized as (data, offsets) — entry di is the byte slice
    # dict_data[dict_offs[di] : dict_offs[di+1]], pushed straight into the
    # builder with no per-entry String alloc.
    var dict_tuple = _materialize_dict(
        streams[lidx].bytes, dict_bytes, is_v2, dict_size
    )
    ref dict_data = dict_tuple[0]
    ref dict_offs = dict_tuple[1]
    var n_entries = len(dict_offs) - 1

    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: DICTIONARY column DATA")
    var indices = decode_int_rle(streams[didx].bytes, n_present, False, is_v2)

    # DICTIONARY STRING tracks validity in the builder, not `acc.present`.
    acc.n_rows += len(present)
    var vi = 0
    for i in range(len(present)):
        if present[i]:
            var di = Int(indices[vi])
            vi += 1
            if di < 0 or di >= n_entries:
                raise Error(
                    "OrcDecodeError.DICT_INDEX_OOB: index "
                    + String(di)
                    + " out of range [0, "
                    + String(n_entries)
                    + ")"
                )
            var ds = Int(dict_offs[di])
            var de = Int(dict_offs[di + 1])
            acc.string_builder.push_bytes(Span(dict_data)[ds:de])
        else:
            acc.string_builder.push_null()


def _materialize_dict(
    length_bytes: List[UInt8],
    dict_bytes: List[UInt8],
    is_v2: Bool,
    dict_size: Int,
) raises -> Tuple[List[UInt8], List[Int32]]:
    """Resolve DICTIONARY_DATA into Arrow (data, offsets) form.

    Returns the dict bytes + an N+1 cumulative-offset list rather than
    a `List[String]` of decoded entries. Entry `di` is the byte slice
    `data[offsets[di] : offsets[di+1]]`. This lets the per-row dict lookup push
    raw bytes into the builder with no per-entry String allocation. The DATA
    bytes are validated to be in-bounds and copied once into the returned List
    (the dict is small relative to the value count, so the copy is cheap and
    keeps the returned data independent of the borrowed stream span).

    ⚠ "VALIDATED TO BE IN-BOUNDS" needs more than `off + ln > total`, which a
    NEGATIVE `ln` passes. See the block comment on the guards below.
    """
    var total = len(dict_bytes)
    var lens = decode_int_rle(length_bytes, dict_size, False, is_v2)
    # ⚠ THE `off + ln > total` CHECK BELOW IS THE ONE A NEGATIVE `ln` WALKS
    # STRAIGHT THROUGH. This LENGTH-stream decoder has its own
    # `decode_int_rle` call, so `_decode_lengths`'s non-negativity guard does
    # not reach it; it calls `_check_lengths_non_negative` itself.
    #
    # With `ln < 0`: `off + ln > total` is trivially FALSE, `off` would walk
    # BACKWARDS and go negative, `offs` would record negative Int32 offsets,
    # and then BOTH consumers would read out of bounds — `List[UInt8](capacity=off)` with
    # a negative capacity, `Span(dict_bytes)[0:off]` as an inverted (negative
    # length) range into a memcpy, and later
    # `Span(dict_data)[dict_offs[di] : dict_offs[di+1]]` in
    # `_decode_string_dict_into` starting before the buffer.
    _check_lengths_non_negative(lens)
    # ARROW-32 OFFSET CEILING. `offs` is `List[Int32]` and `off` is narrowed
    # with a bare `Int32(off)` below. `off` is bounded by `total`, so ONE
    # compare on `total` — before the loop, not inside it — is the whole guard:
    # past 2 GiB of DICTIONARY_DATA the narrowing wraps NEGATIVE while the copy
    # stays correctly sized, and every dict lookup then slices before the data.
    if total > 2147483647:
        raise Error(
            "OrcDecodeError.DICT_DATA_TOO_LARGE: DICTIONARY_DATA holds "
            + String(total)
            + " bytes, exceeding the 2147483647-byte Arrow STRING limit."
            + " The dictionary offsets are Int32; past this size they wrap"
            + " negative while the data buffer stays correctly large, and"
            + " every dictionary lookup then slices before the buffer."
        )
    var offs = List[Int32](capacity=dict_size + 1)
    offs.append(Int32(0))
    var off = 0
    for li in range(dict_size):
        var ln = Int(lens[li])
        if off + ln > total:
            raise Error("OrcDecodeError.DICT_LENGTH_OVERRUN: entry past dict")
        off += ln
        offs.append(Int32(off))
    # `off` is now the total dict byte length; copy exactly that prefix.
    var data = List[UInt8](capacity=off)
    data.extend(Span(dict_bytes)[0:off])
    return (data^, offs^)


# =============================================================================
# SIMD bulk-fill: copy a dense List[Int64] into a PrimitiveArray[dt] data
# buffer in W-wide SIMD chunks.
# =============================================================================
#
# Writing the typed output buffer one element at a time via `arr.set(i, ...)`
# also runs a per-row validity branch under a nullable array, and dominates
# the Arrow build of a wide integer table. This helper bulk-stores the values with a
# single `cast[int64 -> dt]` per SIMD lane and zero per-row branching.
#
# Lowering: `SIMD[int64, W]` load from the dense list + `.cast[dt]()` + an
# `arr.store[W]` (MmapAlignedBuffer.store_simd) per chunk. The tail (< W) is
# handled scalar. The list-pointer load uses a concrete-origin UnsafePointer
# strictly INSIDE this helper (never crosses the module boundary) — the SIMD
# inner-loop exception to the no-raw-pointer rule.


def _check_bulk_fill_extent(n_vals: Int, capacity: Int, what: StringSlice) raises:
    """Reject a bulk-fill whose source is longer than its destination.

    ⚠ THIS IS THE WRITE BOUNDARY, AND THIS IS ITS ONLY CHECK.

    `_bulk_fill_int` / `_bulk_fill_same` loop to `len(vals)` and write through
    `PrimitiveArray.store[W]`, which — unlike `PrimitiveArray.set` — performs
    NO bounds check at ANY assert level (the core packages' `PrimitiveArray.store`
    is a bare `store_simd` on a computed byte offset). The destination is
    allocated to `ColumnAcc.n_rows`. Without this check, the ONLY thing keeping
    these writes in bounds would be the informal invariant
    `len(acc.i64s) == acc.n_rows`.

    An RLEv1 decoder that returns a final run's overshoot would break that
    invariant — by up to 129 values PER STRIPE, cumulative across the whole
    column. `decode_rlev1` truncates at the source, but the invariant is a
    cross-module one between `rle_decode` and this file, so it
    is also ENFORCED here: one compare per column BUILD (not per stripe, not
    per value), on a path that then does O(n_rows) SIMD stores.
    """
    if n_vals > capacity:
        raise Error(
            String("OrcDecodeError.DESTINATION_OVERRUN: ")
            + String(what)
            + " has "
            + String(n_vals)
            + " decoded values but the column was allocated for "
            + String(capacity)
            + " rows. The decoded value count must equal the accumulator's"
            + " row count; a larger one writes past the end of the Arrow data"
            + " buffer (PrimitiveArray.store is unchecked at every ASSERT"
            + " level). This means a stripe's RLE stream produced more values"
            + " than its declared row count."
        )


def _bulk_fill_int[
    dt: DType
](mut arr: PrimitiveArray[dt], vals: List[Int64]) raises:
    """SIMD bulk-copy `vals` (Int64) into `arr`'s data buffer, casting per
    lane to `dt`. `arr` must already be allocated to >= len(vals) — ENFORCED
    below by an explicit raise, not asserted (see `_check_bulk_fill_extent`)."""
    var n = len(vals)
    _check_bulk_fill_extent(n, arr.length, "integer column bulk-fill")
    comptime W = simd_width_of[DType.int64]()
    # SAFETY: `src` is an internal, concrete-origin view of `vals`'s backing
    # store. It is used only for SIMD loads in this function body and never
    # escapes; `vals` is borrowed and outlives the loop.
    var src = vals.unsafe_ptr()
    var i = 0
    var limit = n - (n % W)
    while i < limit:
        var v64 = src.load[width=W](i)
        var narrow = v64.cast[dt]()
        # A value outside `dt` would be truncated by the cast: refuse it.
        # The round trip back to int64 differs exactly when it does not fit.
        comptime if dt != DType.int64:
            if narrow.cast[DType.int64]().ne(v64).reduce_or():
                _refuse_out_of_width[dt](vals, i, W)
        arr.store[W](i, narrow)
        i += W
    while i < n:
        var v = Scalar[dt](vals[i])
        comptime if dt != DType.int64:
            if v.cast[DType.int64]() != vals[i]:
                _refuse_out_of_width[dt](vals, i, 1)
        arr.store[1](i, SIMD[dt, 1](v))
        i += 1


@no_inline
def _refuse_out_of_width[
    dt: DType
](vals: List[Int64], start: Int, count: Int) raises:
    """Raise naming the first of `vals[start : start + count]` that `dt`
    cannot hold (the caller found one there). ORC stores SHORT / INT / DATE
    as 64-bit RLE integers, so a file can carry a value wider than the
    column's Arrow type."""
    var row = start
    for i in range(start + count - 1, start - 1, -1):
        if Scalar[dt](vals[i]).cast[DType.int64]() != vals[i]:
            row = i
    raise Error(
        String("OrcDecodeError.VALUE_OUT_OF_RANGE: row ")
        + String(row)
        + " holds "
        + String(vals[row])
        + ", which does not fit the column's "
        + String(dt)
        + " type"
    )


def _bulk_fill_same[
    dt: DType
](mut arr: PrimitiveArray[dt], vals: List[Scalar[dt]]) raises:
    """SIMD bulk-copy `vals` (already `dt`) into `arr`'s data buffer.

    Same unchecked `store[W]` write boundary as `_bulk_fill_int` — the FLOAT /
    DOUBLE twin of the same shape, guarded identically.
    """
    var n = len(vals)
    _check_bulk_fill_extent(n, arr.length, "float column bulk-fill")
    comptime W = simd_width_of[dt]()
    # SAFETY: internal concrete-origin view of `vals`; SIMD-load only, never
    # escapes; `vals` outlives the loop.
    var src = vals.unsafe_ptr()
    var i = 0
    var limit = n - (n % W)
    while i < limit:
        arr.store[W](i, src.load[width=W](i))
        i += W
    while i < n:
        arr.store[1](i, SIMD[dt, 1](vals[i]))
        i += 1


def _apply_present_nulls[
    dt: DType
](mut arr: PrimitiveArray[dt], present: List[Bool], nc: Int) raises:
    """Mark null positions on a nullable `arr` from the present-flag list."""
    if nc == 0:
        return
    for i in range(len(present)):
        if not present[i]:
            arr._set_null(i)
    arr.null_count = nc


# =============================================================================
# Float bit-reinterpret helpers (LE bytes -> IEEE-754).
# =============================================================================

from std.memory import bitcast


@always_inline
def _u32_to_f32(u: UInt32) -> Float32:
    return bitcast[DType.float32, 1](u)


@always_inline
def _u64_to_f64(u: UInt64) -> Float64:
    return bitcast[DType.float64, 1](u)


# =============================================================================
# No-PRESENT fast-paths.
# =============================================================================
#
# When the column has no PRESENT stream in this stripe, every row is present
# and the per-row interleave (PRESENT-walk + value-dispatch + per-iter
# append) is pure overhead. Each fast-path below:
#
#   1. Skips the `List[Bool]` allocation of present (one Bool append per row
#      per column).
#   2. Skips the `_count_true` scan.
#   3. Decodes values directly into the accumulator's active inner list
#      with no per-row branching. They do not touch `acc.present`; the
#      caller appends n_rows True flags when an earlier stripe had a null.
#
# Pre-condition (caller-enforced in `decode_stripe_column`):
#   `_has_present_stream(streams)` returned False.



@always_inline
def _append_n_true(mut present: List[Bool], n: Int):
    """Append n True flags in bulk (no-null fast path).

    Replaces a per-row `present.append(True)` loop (a bounds-check + store per
    row) with one `resize`
    (pointer-bump given the prior `reserve`) + a byte-memset of the grown
    region — `List[Bool]` stores one byte per element so True is byte value 1.
    """
    var start = len(present)
    present.resize(unsafe_uninit_length=start + n)
    # SAFETY: the freshly-grown region [start, start+n) is uninitialized; we
    # write exactly n bytes through the List's own backing store (concrete
    # origin) and it never escapes. Bool's True bit-pattern is byte value 1.
    unsafe_memset((present.unsafe_ptr() + start).bitcast[UInt8](), UInt8(1), n)


def _no_present_boolean_into(
    mut acc: ColumnAcc, streams: List[StreamSpan], n_rows: Int
) raises:
    """BOOLEAN no-null fast-path: dense bool RLE -> i64 0/1 vals."""
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: BOOLEAN has no DATA")
    var vals = decode_boolean_rle(streams[didx].bytes, n_rows)
    # No PRESENT stream -> every row present. Skip the
    # `present` memset entirely; just bump the row counter.
    acc.n_rows += n_rows
    for i in range(n_rows):
        acc.i64s.append(Int64(1) if vals[i] else Int64(0))


def _no_present_tinyint_into(
    mut acc: ColumnAcc, streams: List[StreamSpan], n_rows: Int
) raises:
    """TINYINT no-null fast-path: dense byte RLE -> i64 with sign-extend."""
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: TINYINT has no DATA")
    var raw = decode_byte_rle(streams[didx].bytes, n_rows)
    acc.n_rows += n_rows
    for i in range(n_rows):
        var b = Int(raw[i])
        if b >= 128:
            b -= 256
        acc.i64s.append(Int64(b))


def _no_present_int_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    n_rows: Int,
    is_v2: Bool,
) raises:
    """Integer (SHORT/INT/LONG/DATE) no-null fast-path.

    Decodes n_rows values via RLE straight into `acc.i64s` (or the BIGINT
    zero-copy buffer) without per-row PRESENT dispatch. This is the
    dominant hit for non-nullable integer columns.

    `List.extend(var other)` memcpys the entire trivially-copyable Int64
    buffer in one shot instead of a per-element `acc.i64s.append(vals[i])`
    loop (one typed-slot write + bounds check per value). `vals` is moved into `acc.i64s`
    so the temporary List's storage transfers ownership (no copy).
    """
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: integer column has no DATA")
    var elem_start = acc.n_rows
    acc.n_rows += n_rows
    if acc.i64_buf_active:
        # BIGINT no-null path decodes straight into the 64B-aligned
        # Arrow output buffer at element `elem_start` — no `i64s` List, no
        # build-time copy. Pass the buffer's capacity byte-span (a safe view;
        # no raw pointer crosses the module boundary).
        decode_int_rle_into_span(
            streams[didx].bytes,
            n_rows,
            True,
            is_v2,
            acc.i64_buf.into_span_capacity(),
            elem_start,
        )
        return
    # Direct write: decode RLE straight into the (pre-reserved) accumulator
    # backing store — no intermediate `vals` List allocation + no `extend`
    # memcpy. Each stripe's decode is a pure resize(pointer-bump) + write.
    decode_int_rle_into(streams[didx].bytes, n_rows, True, is_v2, acc.i64s)


def _no_present_float32_into(
    mut acc: ColumnAcc, streams: List[StreamSpan], n_rows: Int
) raises:
    """FLOAT no-null fast-path: read 4 LE bytes per value with NO
    per-row PRESENT branch + NO `acc.f32s.append(Float32(0))` null arm.
    """
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: FLOAT has no DATA")
    ref data = streams[didx].bytes
    if 4 * n_rows > len(data):
        raise Error("OrcDecodeError.TRUNCATED: FLOAT data overrun")
    acc.n_rows += n_rows
    # ORC FLOAT DATA is contiguous little-endian IEEE-754 = native f32 layout;
    # bulk-copy 4 bytes/value (matches the nullable path's fast arm) instead of
    # per-value scalar byte assembly.
    var start = len(acc.f32s)
    acc.f32s.resize(unsafe_uninit_length=start + n_rows)
    # SAFETY: dst pre-sized to start+n_rows; src has >= 4*n_rows bytes (checked);
    # memcpy is byte-exact + endian-correct on little-endian targets.
    unsafe_memcpy(
        dest=(acc.f32s.unsafe_ptr() + start).bitcast[UInt8](),
        src=data.unsafe_ptr(),
        count=4 * n_rows,
    )


def _no_present_float64_into(
    mut acc: ColumnAcc, streams: List[StreamSpan], n_rows: Int
) raises:
    """DOUBLE no-null fast-path: read 8 LE bytes per value with NO
    per-row PRESENT branch. Hot for any non-nullable DOUBLE column."""
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: DOUBLE has no DATA")
    ref data = streams[didx].bytes
    if 8 * n_rows > len(data):
        raise Error("OrcDecodeError.TRUNCATED: DOUBLE data overrun")
    acc.n_rows += n_rows
    # ORC DOUBLE DATA is contiguous little-endian IEEE-754 = native f64 layout;
    # bulk-copy 8 bytes/value instead of per-value scalar byte assembly.
    var start = len(acc.f64s)
    acc.f64s.resize(unsafe_uninit_length=start + n_rows)
    _bulk_copy_le_f64(data, acc.f64s, start, n_rows)


def _no_present_string_direct_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    n_rows: Int,
    is_v2: Bool,
) raises:
    """STRING DIRECT no-null fast-path: no per-row PRESENT branch + no
    null-arm `acc.strings.append(String(""))`.

    The value bytes are copied as one contiguous block instead of a per-byte
    `s += chr()` concat loop (one String-grow per character on wide string
    columns).
    """
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: STRING has no DATA")
    ref data = streams[didx].bytes
    var lens = _decode_lengths(streams, n_rows, is_v2)
    acc.n_rows += n_rows
    # The values are physically contiguous in the DATA stream (no
    # PRESENT gaps on this path), so copy the whole block in ONE memcpy and
    # prefix-sum the offsets, instead of N per-value `push_bytes` (N memcpy
    # calls + N capacity-check branches + N bounds-checked offset appends),
    # which would dominate the decode of a wide string column.
    # `total` is a running sum of n_rows attacker-chosen lengths, and a
    # post-loop `total > len(data)` test is NOT sufficient: the sum is an
    # unchecked Int accumulation, so individual huge values could WRAP and land
    # back in range while `push_contiguous_block`'s own per-value prefix-sum
    # (`running += Int(lengths[i]); dst[i] = Int32(running)`) walks the Arrow
    # offsets far outside the copied block — producing a StringArray
    # whose offsets point outside its own data buffer, which every later reader
    # of that column then dereferences. (`_decode_lengths` has already
    # guaranteed every `lens[i] >= 0`; the remaining hazard is the SUM.)
    #
    # Checking INSIDE the loop makes the accumulation provably non-overflowing:
    # `total` can never exceed `len(data)` plus one length, so it can never
    # approach Int64. One compare per row on a loop that already does a
    # bounds-checked load and an add — and it short-circuits, so a malformed
    # file costs less than a well-formed one. The builder itself validates
    # nothing (its SAFETY comment says "the value-byte budget validated by the
    # caller's total check"), so this IS that validation.
    var total = 0
    for i in range(n_rows):
        total += Int(lens[i])
        if total > len(data):
            raise Error(
                String("OrcDecodeError.TRUNCATED: STRING value lengths sum to")
                + " more than the "
                + String(len(data))
                + " bytes in the DATA stream (at value "
                + String(i)
                + ")"
            )
    acc.string_builder.push_contiguous_block(Span(data), Span(lens), total)


def _no_present_binary_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    n_rows: Int,
    is_v2: Bool,
) raises:
    """BINARY no-null fast-path. Mirrors STRING DIRECT but builds
    List[UInt8] per value."""
    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: BINARY has no DATA")
    ref data = streams[didx].bytes
    var lens = _decode_lengths(streams, n_rows, is_v2)
    acc.n_rows += n_rows
    var off = 0
    for i in range(n_rows):
        var ln = Int(lens[i])
        if off + ln > len(data):
            raise Error("OrcDecodeError.TRUNCATED: BINARY data overrun")
        var b = List[UInt8]()
        for k in range(off, off + ln):
            b.append(data[k])
        acc.binaries.append(b^)
        off += ln


def _no_present_string_dict_into(
    mut acc: ColumnAcc,
    streams: List[StreamSpan],
    n_rows: Int,
    is_v2: Bool,
    dict_size: Int,
) raises:
    """STRING DICTIONARY no-null fast-path. Skip per-row PRESENT
    interleave; bulk-decode dense indices, then dict-lookup per row."""
    var ddidx = _find_stream(streams, ORC_STREAM_DICTIONARY_DATA)
    if ddidx < 0:
        raise Error(
            "OrcDecodeError.MISSING_DICTIONARY_DATA: DICTIONARY STRING column"
        )
    ref dict_bytes = streams[ddidx].bytes
    var lidx = _find_stream(streams, ORC_STREAM_LENGTH)
    if lidx < 0:
        raise Error("OrcDecodeError.MISSING_LENGTH: DICTIONARY column LENGTH")
    var dict_tuple = _materialize_dict(
        streams[lidx].bytes, dict_bytes, is_v2, dict_size
    )
    ref dict_data = dict_tuple[0]
    ref dict_offs = dict_tuple[1]
    var n_entries = len(dict_offs) - 1

    var didx = _find_stream(streams, ORC_STREAM_DATA)
    if didx < 0:
        raise Error("OrcDecodeError.MISSING_DATA: DICTIONARY column DATA")
    var indices = decode_int_rle(streams[didx].bytes, n_rows, False, is_v2)

    acc.n_rows += n_rows
    for i in range(n_rows):
        var di = Int(indices[i])
        if di < 0 or di >= n_entries:
            raise Error(
                "OrcDecodeError.DICT_INDEX_OOB: index "
                + String(di)
                + " out of range [0, "
                + String(n_entries)
                + ")"
            )
        var ds = Int(dict_offs[di])
        var de = Int(dict_offs[di + 1])
        acc.string_builder.push_bytes(Span(dict_data)[ds:de])
