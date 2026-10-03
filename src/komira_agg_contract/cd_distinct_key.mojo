# =============================================================================
# cd_distinct_key.mojo — THE ONE DEFINITION of what COUNT(DISTINCT) can read
# =============================================================================
#
# ★ WHY THIS MODULE EXISTS. The count-distinct sink keeps its per-group /
#   per-partition state in `Set[Int64]` / `GrowableHashSetI64`, so every agg
#   input value has to become an Int64 DISTINCT KEY. Reading a column's data
#   buffer as `Scalar[DType.int64]` at the row number — an 8-BYTE STRIDE over
#   whatever the column actually holds — gives SILENT WRONG COUNTS for any
#   other type: an int32 column read at an 8-byte stride pairs adjacent
#   elements into one 64-bit word, so N rows yield up to N/2 arbitrary
#   "values"; a string column yields offsets; a dictionary column yields codes
#   that are not even comparable across row groups.
#
# ⛔ The detectors that route INTO the count-distinct kernel and the kernel
#   itself must agree on which value types are readable, so there is ONE
#   definition that the gate and the kernel both read. `cd_distinct_key_channel` is that definition. A type it maps to
#   `CDK_UNSUPPORTED` MUST be refused by every detector, and a type it maps to a
#   channel MUST be read by the kernel through that channel.
#
# ★ THE ADMISSION RULE: a type is supported iff its value domain injects into
#   Int64 with no interning and no per-batch state. Fixed-width integers
#   (any width, signed or unsigned), the int32/int64-storage temporals, BOOL and
#   the two IEEE floats all do. STRING / LARGE_STRING / BINARY need an intern
#   table; DICTIONARY codes are per-row-group and compare across batches only
#   after resolution; DECIMAL128/256 do not fit. Those REFUSE — a refusal is a
#   fine failure mode, a wrong count is not.
#
# ⚠ FLOAT IS NOT A BITCAST. `-0.0 == +0.0` in IEEE, so the two must not count as
#   two distinct values; `cd_f64_distinct_key` folds the sign of zero before
#   taking the bit pattern. FLOAT32 widens to FLOAT64 FIRST, which is injective
#   (every f32 has a distinct f64 image), so one key function serves both.
#   The mixed-aggregate fold delegates here too — the mixed arm and the all-CD
#   sink must agree on a float CD, so the normalisation rule has one copy.
# =============================================================================

from std.collections import List

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch


# The read CHANNEL for one agg input column. `CDK_RAW_I64` is the ONLY one the
# hot kernel may serve with its existing 8-byte-stride pointer read.
comptime CDK_UNSUPPORTED: UInt8 = 255
comptime CDK_RAW_I64: UInt8 = 0    # int64 storage: read verbatim
comptime CDK_I32: UInt8 = 1        # int32 storage (incl. DATE32 / TIME32_*)
comptime CDK_I16: UInt8 = 2
comptime CDK_I8: UInt8 = 3
comptime CDK_U8: UInt8 = 4
comptime CDK_U16: UInt8 = 5
comptime CDK_U32: UInt8 = 6
comptime CDK_U64: UInt8 = 7
comptime CDK_F64: UInt8 = 8
comptime CDK_F32: UInt8 = 9
comptime CDK_BOOL: UInt8 = 10


def cd_distinct_key_channel(at: ArrowType) -> UInt8:
    """The channel a COUNT(DISTINCT) input of this ArrowType must be read
    through, or `CDK_UNSUPPORTED` if its values cannot be keyed as an Int64
    without interning or per-batch state.

    ⛔ THIS IS THE ADMISSION RULE FOR THE WHOLE COUNT(DISTINCT) FAMILY. A
    detector that admits a type this function refuses hands the kernel a column
    it cannot read, and the kernel answers rather than declining."""
    if at == ArrowType.INT64:
        return CDK_RAW_I64
    # int64-STORAGE temporals read verbatim, exactly like INT64. `Column.
    # as_primitive[DType.int64]()` accepts each of these for the same reason.
    if (
        at == ArrowType.DATE64
        or at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
        or at == ArrowType.INTERVAL_DAY_TIME
        or at.is_timestamp()
        or at.is_duration()
    ):
        return CDK_RAW_I64
    if at == ArrowType.INT32:
        return CDK_I32
    # int32-STORAGE temporals.
    if (
        at == ArrowType.DATE32
        or at == ArrowType.TIME32_S
        or at == ArrowType.TIME32_MS
        or at == ArrowType.INTERVAL_YEAR_MONTH
    ):
        return CDK_I32
    if at == ArrowType.INT16:
        return CDK_I16
    if at == ArrowType.INT8:
        return CDK_I8
    if at == ArrowType.UINT8:
        return CDK_U8
    if at == ArrowType.UINT16:
        return CDK_U16
    if at == ArrowType.UINT32:
        return CDK_U32
    if at == ArrowType.UINT64:
        # Bit pattern: distinct UInt64s have distinct Int64 bit patterns, so the
        # DISTINCT COUNT is exact even though the ORDER would not be.
        return CDK_U64
    if at == ArrowType.FLOAT64:
        return CDK_F64
    if at == ArrowType.FLOAT32:
        return CDK_F32
    if at == ArrowType.BOOL:
        return CDK_BOOL
    # STRING / LARGE_STRING / BINARY / DICTIONARY / DECIMAL* / FLOAT16 / nested:
    # no Int64 injection without an intern table or cross-batch resolution.
    return CDK_UNSUPPORTED


def cd_value_type_supported(at: ArrowType) -> Bool:
    """The detector-facing spelling of `cd_distinct_key_channel(at) !=
    CDK_UNSUPPORTED`. A COUNT(DISTINCT) over a column this returns False for
    MUST be declined, never answered."""
    return cd_distinct_key_channel(at) != CDK_UNSUPPORTED


def cd_key_column_type_supported(at: ArrowType) -> Bool:
    """The GROUP KEY admission rule for the single-key streaming CD sink. The
    sink's `WorkerCDState` keys its `Dict` on an Int64, so the same injection
    argument applies — but a key must also ROUND-TRIP into the emitted key
    column, and that emit is INT64-shaped, so the family is narrowed to the
    integer storages the emit can represent (INT32 / INT64 and their temporal
    storage-mates).

    ⚠ NOT the same set as `cd_value_type_supported`, and NOT derived from the
    channel either. The emit (`agg_sink_count_distinct`, the `key_at ==
    ArrowType.INT32` branch) tests those two ArrowTypes LITERALLY: INT32 emits
    a 4-byte column and everything else emits 8. So a DATE32 key — same int32
    STORAGE, same channel — would key correctly and then emit 8-byte data under
    a 4-byte field. This predicate therefore names the two types the emit names,
    and widening it means widening that emit first."""
    return at == ArrowType.INT32 or at == ArrowType.INT64


def cd_f64_distinct_key(v: Float64) -> Int64:
    """The EXACT distinct key for a FLOAT COUNT(DISTINCT) input: the IEEE-754
    bit pattern, with `-0.0` folded onto `+0.0` first because the two compare
    EQUAL in IEEE and must not count as two distinct values.

    ⚠ NaN is left as its literal bit pattern, so two NaNs with different
    payloads count as two, on both the mixed arm and the all-CD sink. This
    is a known divergence from DuckDB (which treats all NaNs as one)."""
    var x = v
    if x == Float64(0.0):
        x = Float64(0.0)
    return UInt64(x.to_bits()).cast[DType.int64]()


def cd_distinct_keys_for_column(
    imm batch: RecordBatch, col_idx: Int
) raises -> List[Int64]:
    """Materialise the per-row Int64 DISTINCT KEY for one agg input column,
    reading it at its OWN width through the typed column accessors (which are
    offset-aware, so a SLICED column is read correctly — the raw-pointer path
    has to add `_offset` by hand and a missing one is a silent wrong answer).

    One pass per column per morsel, so the per-row loop that follows sees a flat
    `List[Int64]` and keeps its shape. The INT64 channel is deliberately served
    here too (for callers with no raw-pointer path) even though the hot kernel
    keeps reading it through its pointer.

    RAISES for `CDK_UNSUPPORTED` — reaching this function with an unsupported
    type means a detector admitted something `cd_value_type_supported` refuses,
    and answering anyway is the defect. The raise names the type."""
    var at = batch.column_arrow_type(col_idx)
    var ch = cd_distinct_key_channel(at)
    var n = batch.num_rows()
    var out = List[Int64](capacity=n)

    if ch == CDK_RAW_I64:
        var c = batch.column_as_primitive_int64(col_idx)
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_I32:
        var c = batch.column_at(col_idx).as_primitive[DType.int32]()
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_I16:
        var c = batch.column_at(col_idx).as_primitive[DType.int16]()
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_I8:
        var c = batch.column_at(col_idx).as_primitive[DType.int8]()
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_U8:
        var c = batch.column_at(col_idx).as_primitive[DType.uint8]()
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_U16:
        var c = batch.column_at(col_idx).as_primitive[DType.uint16]()
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_U32:
        var c = batch.column_at(col_idx).as_primitive[DType.uint32]()
        for r in range(n):
            out.append(Int64(c.get(r)))
    elif ch == CDK_U64:
        var c = batch.column_at(col_idx).as_primitive[DType.uint64]()
        for r in range(n):
            out.append(UInt64(c.get(r)).cast[DType.int64]())
    elif ch == CDK_F64:
        var c = batch.column_as_primitive_float64(col_idx)
        for r in range(n):
            out.append(cd_f64_distinct_key(Float64(c.get(r))))
    elif ch == CDK_F32:
        # F32 -> F64 is INJECTIVE, so widening cannot merge two distinct f32
        # values into one distinct key.
        var c = batch.column_as_primitive_float32(col_idx)
        for r in range(n):
            out.append(cd_f64_distinct_key(Float64(c.get(r))))
    elif ch == CDK_BOOL:
        # A BOOL column is a BITMAP, not a byte array — the one type whose raw
        # buffer read is not merely mis-strided but a different layout entirely.
        var c = batch.column_as_boolean(col_idx)
        for r in range(n):
            out.append(Int64(1) if c.get(r) else Int64(0))
    else:
        raise Error(
            "cd_distinct_keys_for_column: COUNT(DISTINCT) over "
            + String(at)
            + " is not readable as an Int64 distinct key. The caller admitted a"
            " type `cd_value_type_supported` refuses — fix the DETECTOR; a"
            " wrong count is worse than a decline."
        )
    return out^


def cd_null_mask_for_column(
    imm batch: RecordBatch, col_idx: Int
) raises -> List[Bool]:
    """The per-row NULL flag for one agg input column, read through the SAME
    typed accessor `cd_distinct_keys_for_column` uses — so the two lists are
    always about the same column read the same way.

    ⚠ THE VALUES LIST IS NOT A NULL ORACLE. `cd_distinct_keys_for_column` reads
    a NULL row's raw payload like any other, because Arrow leaves it
    unspecified and the caller is expected to gate on this mask. A caller that
    takes one without the other counts NULL rows as distinct values.

    RAISES for an unsupported type, for the same reason as its sibling."""
    var at = batch.column_arrow_type(col_idx)
    var ch = cd_distinct_key_channel(at)
    var n = batch.num_rows()
    var out = List[Bool](capacity=n)

    if ch == CDK_RAW_I64:
        var c = batch.column_as_primitive_int64(col_idx)
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_I32:
        var c = batch.column_at(col_idx).as_primitive[DType.int32]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_I16:
        var c = batch.column_at(col_idx).as_primitive[DType.int16]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_I8:
        var c = batch.column_at(col_idx).as_primitive[DType.int8]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_U8:
        var c = batch.column_at(col_idx).as_primitive[DType.uint8]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_U16:
        var c = batch.column_at(col_idx).as_primitive[DType.uint16]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_U32:
        var c = batch.column_at(col_idx).as_primitive[DType.uint32]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_U64:
        var c = batch.column_at(col_idx).as_primitive[DType.uint64]()
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_F64:
        var c = batch.column_as_primitive_float64(col_idx)
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_F32:
        var c = batch.column_as_primitive_float32(col_idx)
        for r in range(n):
            out.append(c.is_null(r))
    elif ch == CDK_BOOL:
        var c = batch.column_as_boolean(col_idx)
        for r in range(n):
            out.append(c.is_null(r))
    else:
        raise Error(
            "cd_null_mask_for_column: COUNT(DISTINCT) over "
            + String(at)
            + " is not readable as an Int64 distinct key — fix the DETECTOR."
        )
    return out^
