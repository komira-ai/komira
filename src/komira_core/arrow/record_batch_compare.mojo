# =============================================================================
# record_batch_compare.mojo -- byte-identical RecordBatch comparison for a
# differential-correctness gate.
#
# This module provides a structural, byte-identical equality check between two
# `RecordBatch` values. It is the foundation of a differential-correctness
# harness: the harness runs a query through two execution-path arms and
# asserts the output `RecordBatch` is byte-identical. "Byte-identical" here
# means:
#
#   1. Schema agreement: same column count, same field names, same Arrow types,
#      same nullability flags (+ decimal precision/scale for DECIMAL128).
#   2. Same row count.
#   3. Per column, per row: same validity bit (null vs non-null), and for the
#      non-null rows, the SAME value. For floating-point columns the comparison
#      is BIT-EXACT (`bitcast` to the integer domain) so that `+0.0`/`-0.0` and
#      NaN payloads are distinguished — a differential gate that tolerated
#      float-equality fuzz would silently pass a re-association regression.
#
# Why typed accessors, not raw buffers:
#   Per the encapsulation rule, `UnsafePointer` must never
#   cross a module boundary. This module compares via the public typed-array
#   accessors (`column_as_primitive_*`, `column_as_string`, `column_as_boolean`,
#   `as_decimal128`) + `.get(i)` / `.is_null(i)`. No raw pointer arithmetic, no
#   wildcard origins. The cost is one type-erase->typed-array materialization
#   per column; the gate runs on small output batches (agg results, filtered
#   slices) so this is not on any hot path.
#
# Float-agg / ordering tolerance:
#   Group-by aggregations can emit groups in a hash-iteration order that
#   differs from another engine's `ORDER BY`. This module compares ROW-BY-ROW in
#   the order the batches present their rows; it does NOT sort. A query whose
#   group order is non-deterministic across arms is therefore a RED here unless
#   the harness pins a stable order (the harness documents this). The compare
#   utility itself stays strict (no implicit sort) so a real row-reordering
#   regression cannot hide behind a tolerant comparator.
# =============================================================================

from std.memory import bitcast

from .record_batch import RecordBatch
from .arrow_types import ArrowType


@fieldwise_init
struct RecordBatchDiff(Copyable, Movable, Writable):
    """Result of a `record_batch_diff` comparison.

    `equal` is True iff the two batches are byte-identical. When False,
    `reason` carries a human-readable description of the FIRST divergence
    found (schema mismatch, row-count mismatch, or the column/row index +
    nature of the first cell that differs).
    """

    var equal: Bool
    var reason: String

    def write_to[W: Writer](self, mut writer: W):
        if self.equal:
            writer.write("RecordBatchDiff(equal=True)")
        else:
            writer.write("RecordBatchDiff(equal=False, reason='")
            writer.write(self.reason)
            writer.write("')")


def _schema_diff(a: RecordBatch, b: RecordBatch) raises -> String:
    """Return "" if schemas agree byte-for-byte, else the first divergence."""
    var na = a.num_columns()
    var nb = b.num_columns()
    if na != nb:
        return (
            "column count differs: arm A has "
            + String(na)
            + " columns, arm B has "
            + String(nb)
        )
    for c in range(na):
        var name_a = a.schema.field_name(c)
        var name_b = b.schema.field_name(c)
        if name_a != name_b:
            return (
                "field name differs at column "
                + String(c)
                + ": A='"
                + name_a
                + "' B='"
                + name_b
                + "'"
            )
        var ta = a.column_arrow_type(c)
        var tb = b.column_arrow_type(c)
        if ta != tb:
            return (
                "arrow type differs at column "
                + String(c)
                + " ('"
                + name_a
                + "'): A="
                + String(ta)
                + " B="
                + String(tb)
            )
        var null_a = a.schema.field_nullable(c)
        var null_b = b.schema.field_nullable(c)
        if null_a != null_b:
            return (
                "nullability differs at column "
                + String(c)
                + " ('"
                + name_a
                + "'): A="
                + String(null_a)
                + " B="
                + String(null_b)
            )
        if ta == ArrowType.DECIMAL128:
            var pa = a.schema.field_decimal_precision(c)
            var pb = b.schema.field_decimal_precision(c)
            var sa = a.schema.field_decimal_scale(c)
            var sb = b.schema.field_decimal_scale(c)
            if pa != pb or sa != sb:
                return (
                    "decimal precision/scale differs at column "
                    + String(c)
                    + " ('"
                    + name_a
                    + "'): A=("
                    + String(pa)
                    + ","
                    + String(sa)
                    + ") B=("
                    + String(pb)
                    + ","
                    + String(sb)
                    + ")"
                )
    return String("")


def _cell_loc(col: Int, row: Int, name: String) -> String:
    return "column " + String(col) + " ('" + name + "') row " + String(row)


def _diff_primitive[
    dtype: DType
](a: RecordBatch, b: RecordBatch, c: Int, name: String) raises -> String:
    """Compare a primitive column bit-exactly. For float dtypes the value
    comparison is performed in the integer bit domain so +0.0/-0.0 and NaN
    payloads are distinguished."""
    var arr_a = a.column_at(c).as_primitive[dtype]()
    var arr_b = b.column_at(c).as_primitive[dtype]()
    var n = a.num_rows()
    for r in range(n):
        var na = arr_a.is_null(r)
        var nb = arr_b.is_null(r)
        if na != nb:
            return (
                "validity differs at "
                + _cell_loc(c, r, name)
                + ": A.is_null="
                + String(na)
                + " B.is_null="
                + String(nb)
            )
        if na:
            continue
        var va = arr_a.get(r)
        var vb = arr_b.get(r)

        comptime if (
            dtype == DType.float16
            or dtype == DType.float32
            or dtype == DType.float64
        ):
            # Bit-exact float compare via the matching-width integer domain.
            comptime if dtype == DType.float64:
                if bitcast[DType.uint64, width=1](va) != bitcast[
                    DType.uint64, width=1
                ](vb):
                    return (
                        "float64 value differs (bit-exact) at "
                        + _cell_loc(c, r, name)
                        + ": A="
                        + String(va)
                        + " B="
                        + String(vb)
                    )
            elif dtype == DType.float32:
                if bitcast[DType.uint32, width=1](va) != bitcast[
                    DType.uint32, width=1
                ](vb):
                    return (
                        "float32 value differs (bit-exact) at "
                        + _cell_loc(c, r, name)
                        + ": A="
                        + String(va)
                        + " B="
                        + String(vb)
                    )
            else:
                if bitcast[DType.uint16, width=1](va) != bitcast[
                    DType.uint16, width=1
                ](vb):
                    return (
                        "float16 value differs (bit-exact) at "
                        + _cell_loc(c, r, name)
                        + ": A="
                        + String(va)
                        + " B="
                        + String(vb)
                    )
        else:
            if va != vb:
                return (
                    "value differs at "
                    + _cell_loc(c, r, name)
                    + ": A="
                    + String(va)
                    + " B="
                    + String(vb)
                )
    return String("")


def _diff_string(
    a: RecordBatch, b: RecordBatch, c: Int, name: String
) raises -> String:
    var arr_a = a.column_at(c).as_string()
    var arr_b = b.column_at(c).as_string()
    var n = a.num_rows()
    for r in range(n):
        var na = arr_a.is_null(r)
        var nb = arr_b.is_null(r)
        if na != nb:
            return (
                "validity differs at "
                + _cell_loc(c, r, name)
                + ": A.is_null="
                + String(na)
                + " B.is_null="
                + String(nb)
            )
        if na:
            continue
        var va = arr_a.get(r)
        var vb = arr_b.get(r)
        if va != vb:
            return (
                "string value differs at "
                + _cell_loc(c, r, name)
                + ": A='"
                + va
                + "' B='"
                + vb
                + "'"
            )
    return String("")


def _diff_boolean(
    a: RecordBatch, b: RecordBatch, c: Int, name: String
) raises -> String:
    var arr_a = a.column_at(c).as_boolean()
    var arr_b = b.column_at(c).as_boolean()
    var n = a.num_rows()
    for r in range(n):
        var na = arr_a.is_null(r)
        var nb = arr_b.is_null(r)
        if na != nb:
            return (
                "validity differs at "
                + _cell_loc(c, r, name)
                + ": A.is_null="
                + String(na)
                + " B.is_null="
                + String(nb)
            )
        if na:
            continue
        var va = arr_a.get(r)
        var vb = arr_b.get(r)
        if va != vb:
            return (
                "bool value differs at "
                + _cell_loc(c, r, name)
                + ": A="
                + String(va)
                + " B="
                + String(vb)
            )
    return String("")


def _diff_column(
    a: RecordBatch, b: RecordBatch, c: Int
) raises -> String:
    """Compare column `c` cell-by-cell. Returns "" if identical, else the
    first divergence. Dispatches on the (already schema-agreed) Arrow type."""
    var name = a.schema.field_name(c)
    var t = a.column_arrow_type(c)

    if t == ArrowType.BOOL:
        return _diff_boolean(a, b, c, name)
    elif t == ArrowType.INT8:
        return _diff_primitive[DType.int8](a, b, c, name)
    elif t == ArrowType.INT16:
        return _diff_primitive[DType.int16](a, b, c, name)
    elif t == ArrowType.INT32 or t == ArrowType.DATE32:
        return _diff_primitive[DType.int32](a, b, c, name)
    elif (
        t == ArrowType.INT64
        or t == ArrowType.DATE64
        or t == ArrowType.TIMESTAMP
        or t == ArrowType.TIMESTAMP_S
        or t == ArrowType.TIMESTAMP_MS
        or t == ArrowType.TIMESTAMP_US
        or t == ArrowType.TIMESTAMP_NS
    ):
        return _diff_primitive[DType.int64](a, b, c, name)
    elif t == ArrowType.UINT8:
        return _diff_primitive[DType.uint8](a, b, c, name)
    elif t == ArrowType.UINT16:
        return _diff_primitive[DType.uint16](a, b, c, name)
    elif t == ArrowType.UINT32:
        return _diff_primitive[DType.uint32](a, b, c, name)
    elif t == ArrowType.UINT64:
        return _diff_primitive[DType.uint64](a, b, c, name)
    elif t == ArrowType.FLOAT16:
        return _diff_primitive[DType.float16](a, b, c, name)
    elif t == ArrowType.FLOAT32:
        return _diff_primitive[DType.float32](a, b, c, name)
    elif t == ArrowType.FLOAT64:
        return _diff_primitive[DType.float64](a, b, c, name)
    elif t == ArrowType.STRING or t == ArrowType.LARGE_STRING:
        return _diff_string(a, b, c, name)
    else:
        # DECIMAL128 / DICTIONARY / LIST / STRUCT / BINARY: not supported by
        # this byte-compare. Surface as an
        # explicit "unsupported by the byte-compare" reason rather than a
        # silent pass, so a future query that emits these types fails loud
        # and prompts extending this dispatch.
        return (
            "column "
            + String(c)
            + " ('"
            + name
            + "') has Arrow type "
            + String(t)
            + " which the U-I byte-compare does not yet support — extend "
            + "_diff_column"
        )


def record_batch_diff(a: RecordBatch, b: RecordBatch) raises -> RecordBatchDiff:
    """Compare two RecordBatches for byte-identical equality.

    Returns a `RecordBatchDiff` whose `equal` is True iff the two batches
    agree on schema, row count, and every cell (validity bit + value,
    bit-exact for floats). On the first divergence, `equal` is False and
    `reason` describes it.

    This is the comparator a differential-correctness harness wraps;
    it is intentionally STRICT (no implicit row sort, bit-exact float
    compare) so a real correctness regression cannot hide behind comparator
    fuzz.
    """
    var sd = _schema_diff(a, b)
    if sd != "":
        return RecordBatchDiff(False, sd)

    var ra = a.num_rows()
    var rb = b.num_rows()
    if ra != rb:
        return RecordBatchDiff(
            False,
            "row count differs: arm A has "
            + String(ra)
            + " rows, arm B has "
            + String(rb),
        )

    for c in range(a.num_columns()):
        var cd = _diff_column(a, b, c)
        if cd != "":
            return RecordBatchDiff(False, cd)

    return RecordBatchDiff(True, String(""))


def record_batch_byte_equal(a: RecordBatch, b: RecordBatch) raises -> Bool:
    """Convenience boolean form of `record_batch_diff`."""
    return record_batch_diff(a, b).equal
