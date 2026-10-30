# =============================================================================
# column_decimal: DECIMAL128 and temporal typing, promotion, casts, scalar folds
# =============================================================================
#
# Resolves a column's decimal precision and scale and its temporal unit, pairs
# two operands for DECIMAL128 arithmetic, promotes an operand to FLOAT64 or
# DECIMAL128, casts to and from DECIMAL128, and reduces a column to the scalar
# an aggregate over a whole batch produces.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import (
    eval_add,
    eval_div,
    eval_mul,
    eval_sub,
)
from komira_column_kernels.compiler_helpers import int64_to_float64, merge_binary_arith_validity
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
)
from komira_plan_expr.expr import (
    BIN_ADD,
    BIN_DIV,
    BIN_MUL,
    BIN_SUB,
    EXPR_ALIAS,
    EXPR_COL_REF,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_scalar_arithmetic.decimal_arith import (
    I128,
    decimal_add_i128,
    decimal_add_result_ps,
    decimal_div_i128,
    decimal_div_result_ps,
    decimal_mul_i128,
    decimal_mul_result_ps,
    decimal_sub_i128,
)
from komira_scalar_arithmetic.decimal_cast import (
    decimal_rescale_i128,
    decimal_to_float64,
    decimal_to_int64,
    decimal_to_string,
    float_to_decimal_i128,
    int_to_decimal_i128,
    string_to_decimal_i128,
)


# =============================================================================
# DECIMAL128 — column binary arithmetic + casts
# =============================================================================
#
# Scalar per-row loops over native
# int128 — perf is explicitly not the goal here.  The result Column carries
# the result (precision, scale).  Validity = AND(left, right) (the correct
# behavior — net-new code, no validity-drop legacy bug).


def _resolve_decimal_ps(col: Column[HeapRegion], batch: RecordBatch, name_hint: String) raises -> Tuple[Int, Int]:
    """(precision, scale) for a DECIMAL128 column — prefers the column's own
    metadata, else looks the field up in the batch schema by name."""
    if col.decimal_precision() > 0:
        return (col.decimal_precision(), col.decimal_scale())
    # Fall back to the batch schema.
    try:
        var idx = batch.schema.column_index(name_hint)
        return (batch.schema.field_decimal_precision(idx), batch.schema.field_decimal_scale(idx))
    except e:
        raise Error("Decimal128: column carries no (precision, scale) and not found in schema")


def _resolve_temporal_arrow_type(
    col: Column[HeapRegion], batch: RecordBatch, name_hint: String
) -> ArrowType:
    """The TEMPORAL type of `col` — from the column's own stamp if it has one,
    else from the batch SCHEMA's field of that name. `ArrowType.NULL` when
    neither says temporal.

    ★★ THIS EXISTS BECAUSE THE PARQUET READER DOES NOT STAMP THE COLUMN, AND
    THAT IS THE LIVE PRODUCTION SHAPE — not an edge case. A DATE32 is
    physically int32 days and a TIMESTAMP_* is physically int64 ticks, and the
    decode path hands back a Column whose `arrow_type` is the PHYSICAL one
    while the FIELD in `batch.schema` carries the logical temporal type
    (`komira_parquet/decode_helpers.mojo` builds a tz-carrying Timestamp Field;
    `test_date32_predicate_filter` calls the INT32-stamped date column "the
    LIVE production shape" in as many words).

    ⛔ AND IT IS THE REASON THIS HELPER IS NOT A TIDY-UP:
    `SELECT year(d) FROM read_parquet(...)` over a DATE32 column failed with
    `PipelineCompiler: EXPR_EXTRACT child must be DATE32 or TIMESTAMP_*, got
    type_id=4` — type_id 4 is INT32. So `EXPR_EXTRACT` had NEVER been reachable
    over a parquet scan, through ANY door: the whole temporal family works in
    the unit suites only because those hand-stamp an in-memory batch. A
    capability can be fully implemented, wired end to end, and reachable from
    nothing.

    ⚠ THE SCHEMA IS CONSULTED, NOT GUESSED, AND THE DIFFERENCE IS THE WHOLE
    SAFETY ARGUMENT. Reading "int32 means DATE32, int64 means TIMESTAMP" off
    the BUFFER WIDTH would make `year(some_bigint_column)` answer a plausible
    year instead of refusing — a silent wrong answer on a column that is not a
    date at all. This only ever promotes a column whose own schema field SAYS
    it is temporal; anything else falls through to the caller's refusal.

    ★ THE SHAPE IS `_resolve_decimal_ps`'s, deliberately. DECIMAL128 has the
    identical problem (precision/scale live on the field, not always on the
    column) and solved it this way; a second, differently-shaped answer to the
    same question is how two paths drift.
    """
    var own = col.arrow_type
    if (
        own == ArrowType.DATE32
        or own == ArrowType.TIMESTAMP
        or own == ArrowType.TIMESTAMP_S
        or own == ArrowType.TIMESTAMP_MS
        or own == ArrowType.TIMESTAMP_US
        or own == ArrowType.TIMESTAMP_NS
    ):
        return own
    # An unstamped column can only be promoted from its PHYSICAL width, and
    # only when the schema agrees: int32 <- DATE32, int64 <- TIMESTAMP_*.
    if own != ArrowType.INT32 and own != ArrowType.INT64:
        return ArrowType.NULL
    if name_hint.byte_length() == 0:
        return ArrowType.NULL
    try:
        var idx = batch.schema.column_index(name_hint)
        var declared = batch.schema.field_arrow_type(idx)
        if own == ArrowType.INT32 and declared == ArrowType.DATE32:
            return declared
        if own == ArrowType.INT64 and (
            declared == ArrowType.TIMESTAMP
            or declared == ArrowType.TIMESTAMP_S
            or declared == ArrowType.TIMESTAMP_MS
            or declared == ArrowType.TIMESTAMP_US
            or declared == ArrowType.TIMESTAMP_NS
        ):
            return declared
        return ArrowType.NULL
    except e:
        # Not a named column of this batch (a computed child), so there is no
        # declaration to promote from. Refusing is correct.
        return ArrowType.NULL


def _decimal_col_to_i128(col: Column[HeapRegion]) raises -> List[I128]:
    """Materialize a DECIMAL128 column's values as native int128s."""
    var n = col.length()
    var out = List[I128]()
    var arr = col.as_decimal128()
    for i in range(n):
        out.append(arr.get_i128(i))
    return out^


def _eval_decimal_binary_pair(
    left_col: Column[HeapRegion],
    right_col: Column[HeapRegion],
    op: UInt8,
    batch: RecordBatch,
    l_name: String,
    r_name: String,
) raises -> Column[HeapRegion]:
    """`left <op> right` where AT LEAST ONE side is DECIMAL128 -- the ONE
    decimal arithmetic arm. The column-column path calls it, and so does the
    scalar fast path once it has broadcast the literal (a decimal column
    against a literal, or a DECIMAL literal against any column), so a literal
    operand cannot take a different rule from a column one."""
    # decimal {+,-,*,/} decimal (with scale
    # alignment).  Mixed decimal/int -> promote the int to a decimal
    # at the decimal's scale.  Mixed decimal/float -> promote the
    # decimal to float64 and do float arithmetic (decimal "loses" to
    # float in the SQL coercion lattice — matches DuckDB/DataFusion).
    if left_col.arrow_type == ArrowType.DECIMAL128 and right_col.arrow_type == ArrowType.DECIMAL128:
        if op == BIN_DIV:
            # ⛔ DECIMAL / DECIMAL IS DOUBLE. Dividing in DECIMAL at the
            # Hive scale s1 + 4 gives `dc / dp` = decimal(18,6)
            # 29.285714 where DuckDB 1.5.3 answers DOUBLE 29.28571428571429 (a
            # VALUE divergence, not type-only), and a zero divisor RAISED
            # `Decimal128 division by zero` where DuckDB answers inf / nan.
            # DuckDB converts both sides to DOUBLE and divides (IEEE), as the
            # decimal / BIGINT arm below already does; `walk_expr_field`
            # declares FLOAT64 for it.
            var lq = _promote_to_float64(left_col, batch, l_name)
            var rq = _promote_to_float64(right_col, batch, r_name)
            var q = eval_div[DType.float64](lq, rq)
            merge_binary_arith_validity[DType.float64](left_col, right_col, q)
            return Column.from_primitive[DType.float64](q)
        return _decimal_binary_col(left_col, right_col, op, batch, l_name, r_name)
    elif left_col.arrow_type == ArrowType.FLOAT64 or right_col.arrow_type == ArrowType.FLOAT64:
        # Promote the decimal side to float64; fall through to a fresh
        # float64-float64 eval.
        var lf = _promote_to_float64(left_col, batch, l_name)
        var rf = _promote_to_float64(right_col, batch, r_name)
        var result: PrimitiveArray[DType.float64]
        if op == BIN_ADD:
            result = eval_add[DType.float64](lf, rf)
        elif op == BIN_SUB:
            result = eval_sub[DType.float64](lf, rf)
        elif op == BIN_MUL:
            result = eval_mul[DType.float64](lf, rf)
        elif op == BIN_DIV:
            result = eval_div[DType.float64](lf, rf)
        else:
            raise Error("PipelineCompiler: unsupported decimal/float binary op: " + String(Int(op)))
        # ⛔ THE ONE ARITHMETIC ARM THAT MUST NOT SKIP THE VALIDITY MERGE:
        # without it a NULL decimal
        # row came back VALID, holding whatever the kernel computed
        # over its payload -- `120.0 / NULL` answered `inf` at the
        # untyped Mojo and typed doors where DuckDB answers NULL.
        merge_binary_arith_validity[DType.float64](left_col, right_col, result)
        return Column.from_primitive[DType.float64](result)
    elif left_col.arrow_type == ArrowType.INT64 or right_col.arrow_type == ArrowType.INT64:
        # ⛔ DECIMAL (op) INTEGER COLUMN.
        # This arm promoted the int to a DECIMAL AT THE DECIMAL'S SCALE for
        # EVERY op and ran the decimal kernel, while `walk_expr_field`
        # declared the DECIMAL side's (p, s) -- and the batch is stamped
        # with the DECLARED type. MEASURED at the SQL door, dc
        # decimal(12,2) = 10.25, nn int64 = 1: `dc * nn` came back
        # 1025.00 (the product at scale 4, relabelled scale 2: x100) and
        # `dc / nn` 102500.00 (the quotient at scale s+4: x10^4); `nn /
        # dc` and `120 / dc` likewise, silently. DuckDB 1.5.3:
        #   `/`  -> DOUBLE (IEEE: x / 0 = inf, 0 / 0 = nan)
        #   `*`  -> the int is DECIMAL(19, 0): result scale s1 + 0
        #   `+ -`-> aligned at the decimal's scale (what this arm did)
        # and `walk_expr_field` now declares the same (FLOAT64 for `/`).
        if op == BIN_DIV:
            var lq = _promote_to_float64(left_col, batch, l_name)
            var rq = _promote_to_float64(right_col, batch, r_name)
            var q = eval_div[DType.float64](lq, rq)
            merge_binary_arith_validity[DType.float64](left_col, right_col, q)
            return Column.from_primitive[DType.float64](q)
        if op == BIN_MUL:
            var lm = _promote_int_to_decimal_scale0(left_col)
            var rm = _promote_int_to_decimal_scale0(right_col)
            return _decimal_binary_col(lm, rm, op, batch, l_name, r_name)
        # Promote the int side to a DECIMAL128 at the decimal's scale.
        var ld = _promote_to_decimal(left_col, right_col, batch, l_name, r_name)
        var rd = _promote_to_decimal(right_col, left_col, batch, r_name, l_name)
        return _decimal_binary_col(ld, rd, op, batch, l_name, r_name)
    else:
        raise Error(
            "PipelineCompiler: unsupported decimal binary-op operand combination: "
            + String(left_col.arrow_type) + " and " + String(right_col.arrow_type)
        )


def _decimal_binary_col(left_col: Column[HeapRegion], right_col: Column[HeapRegion], op: UInt8, batch: RecordBatch, left_name: String, right_name: String) raises -> Column[HeapRegion]:
    """col {+,-,*,/} col for DECIMAL128 columns (with scale alignment)."""
    var ps1 = _resolve_decimal_ps(left_col, batch, left_name)
    var ps2 = _resolve_decimal_ps(right_col, batch, right_name)
    var p1 = ps1[0]
    var s1 = ps1[1]
    var p2 = ps2[0]
    var s2 = ps2[1]
    var n = left_col.length()
    if right_col.length() != n:
        raise Error("Decimal128 binary op: column length mismatch")
    var lv = _decimal_col_to_i128(left_col)
    var rv = _decimal_col_to_i128(right_col)
    # Result (p, s).
    var rp: Int
    var rs: Int
    if op == BIN_ADD or op == BIN_SUB:
        var ps = decimal_add_result_ps(p1, s1, p2, s2)
        rp = ps[0]
        rs = ps[1]
    elif op == BIN_MUL:
        var ps = decimal_mul_result_ps(p1, s1, p2, s2)
        rp = ps[0]
        rs = ps[1]
    elif op == BIN_DIV:
        var ps = decimal_div_result_ps(p1, s1, p2, s2)
        rp = ps[0]
        rs = ps[1]
    else:
        raise Error("Decimal128: unsupported binary op " + String(Int(op)))
    # validity = AND(left, right).
    var has_a = Bool(left_col._validity)
    var has_b = Bool(right_col._validity)
    var validity = Optional[Bitmap[HeapRegion]](None)
    var nulls = 0
    if has_a or has_b:
        var bm = Bitmap.create_all_valid(n)
        for i in range(n):
            var valid = True
            if has_a:
                if not left_col._validity.value().test(left_col._offset + i):
                    valid = False
            if valid and has_b:
                if not right_col._validity.value().test(right_col._offset + i):
                    valid = False
            if not valid:
                bm.clear(i)
                nulls += 1
        validity = bm^
    var out = Decimal128Array.allocate(n, rp, rs)
    for i in range(n):
        # Skip computing for null slots (value bytes are zero-filled;
        # division by a null operand value would otherwise be div-by-zero).
        if validity:
            if not validity.value().test(i):
                out.set_i128(i, I128(0))
                continue
        var rval: I128
        if op == BIN_ADD:
            rval = decimal_add_i128(lv[i], s1, rv[i], s2, rs)
        elif op == BIN_SUB:
            rval = decimal_sub_i128(lv[i], s1, rv[i], s2, rs)
        elif op == BIN_MUL:
            rval = decimal_mul_i128(lv[i], rv[i])
        else:  # BIN_DIV
            rval = decimal_div_i128(lv[i], s1, rv[i], s2, rs)
        out.set_i128(i, rval)
    var col = Column.from_decimal128(out)
    col._validity = validity^
    col._null_count = nulls
    return col^


def _expr_name_hint(expr: Expr) -> String:
    """Best-effort column name for a (possibly aliased) column-ref Expr.
    Returns "" if it's not a plain column reference."""
    if expr.tag == EXPR_COL_REF:
        return expr.col_ref_name()
    elif expr.tag == EXPR_ALIAS:
        return _expr_name_hint(expr.alias_child_ref())
    return ""


def _promote_to_float64(col: Column[HeapRegion], batch: RecordBatch, name_hint: String) raises -> PrimitiveArray[DType.float64]:
    """Cast a DECIMAL128 / INT64 / FLOAT64 column to a float64 PrimitiveArray."""
    if col.arrow_type == ArrowType.FLOAT64:
        return col.as_primitive[DType.float64]()
    if col.arrow_type == ArrowType.INT64:
        return int64_to_float64(col.as_primitive[DType.int64]())
    if col.arrow_type == ArrowType.DECIMAL128:
        var ps = _resolve_decimal_ps(col, batch, name_hint)
        var s = ps[1]
        var n = col.length()
        var arr = col.as_decimal128()
        var out = PrimitiveArray[DType.float64].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, decimal_to_float64(arr.get_i128(i), s))
        out.null_count = nulls
        return out^
    raise Error("_promote_to_float64: unsupported source type " + String(col.arrow_type))


def _promote_int_to_decimal_scale0(col: Column[HeapRegion]) raises -> Column[HeapRegion]:
    """A DECIMAL128 column is copied; an INT64 column becomes DECIMAL(19, 0) --
    DuckDB's own type for a BIGINT operand of a decimal `*` (so the product's
    scale is the decimal side's scale plus 0)."""
    if col.arrow_type == ArrowType.DECIMAL128:
        return Column.from_decimal128(col.as_decimal128())
    if col.arrow_type == ArrowType.INT64:
        var n = col.length()
        var src = col.as_primitive[DType.int64]()
        var out = Decimal128Array.allocate_nullable(n, 19, 0)
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, I128(Int(src.get(i))))
        return Column.from_decimal128(out)
    raise Error(
        "_promote_int_to_decimal_scale0: unsupported source type "
        + String(col.arrow_type)
    )


def _promote_to_decimal(col: Column[HeapRegion], other: Column[HeapRegion], batch: RecordBatch, name_hint: String, other_hint: String) raises -> Column[HeapRegion]:
    """If `col` is DECIMAL128, return a copy.  If INT64, promote to a
    DECIMAL128 at `other`'s scale (with enough precision; capped at 38)."""
    if col.arrow_type == ArrowType.DECIMAL128:
        return Column.from_decimal128(col.as_decimal128())
    if col.arrow_type == ArrowType.INT64:
        var ps = _resolve_decimal_ps(other, batch, other_hint)
        var s = ps[1]
        # An Int64 has <= 19 digits; promote to D(min(38, 19+s), s).
        var p = 19 + s
        if p > 38:
            p = 38
        var n = col.length()
        var src = col.as_primitive[DType.int64]()
        var out = Decimal128Array.allocate_nullable(n, p, s)
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, int_to_decimal_i128(src.get(i), p, s))
        return Column.from_decimal128(out)
    raise Error("_promote_to_decimal: unsupported source type " + String(col.arrow_type))


@always_inline
def _ts_unit_factor(src: ArrowType, dst: ArrowType) -> Int64:
    """Return the unit scale factor mapping `src` timestamp unit to `dst`.

    Convention:
    - Returns 0 if `src == dst` (no scale).
    - Returns +factor (positive) if `dst` is FINER than `src` (multiply).
    - Returns -factor (negative; caller negates) if `dst` is COARSER than
      `src` (divide).

    Units: TIMESTAMP_S = 0, TIMESTAMP_MS = 1, TIMESTAMP_US = 2,
    TIMESTAMP_NS = 3. Each step is ×1000. Legacy `TIMESTAMP` (no unit) is
    treated as TIMESTAMP_US (microseconds; matches the legacy default).
    """
    var s = _ts_unit_rank(src)
    var d = _ts_unit_rank(dst)
    if s == d:
        return Int64(0)
    var diff = d - s
    # ×1000 per step. Pre-compute via a small switch on |diff|.
    var abs_diff = diff if diff > 0 else -diff
    var factor: Int64
    if abs_diff == 1:
        factor = Int64(1000)
    elif abs_diff == 2:
        factor = Int64(1_000_000)
    elif abs_diff == 3:
        factor = Int64(1_000_000_000)
    else:
        factor = Int64(1)
    if diff > 0:
        return factor
    else:
        return -factor


@always_inline
def _ts_unit_rank(at: ArrowType) -> Int:
    """Rank a TIMESTAMP_* unit on the [0..3] scale: s=0, ms=1, us=2, ns=3.

    Legacy unitless `TIMESTAMP` maps to us (rank 2) by default.
    """
    if at == ArrowType.TIMESTAMP_S:
        return 0
    elif at == ArrowType.TIMESTAMP_MS:
        return 1
    elif at == ArrowType.TIMESTAMP_NS:
        return 3
    else:
        # TIMESTAMP_US and legacy TIMESTAMP both rank as us (2).
        return 2


def _scaled_integer_to_decimal_i128(v: I128, p: Int, s: Int) raises -> I128:
    """The integer `v` as the unscaled value of DECIMAL(p, s): `v * 10^s`,
    refused when it has more than `p` digits."""
    var scaled = v
    for _ in range(s):
        scaled = scaled * I128(10)
    var limit = I128(1)
    for _ in range(p):
        limit = limit * I128(10)
    if scaled >= limit or scaled <= -limit:
        raise Error(
            "CAST to DECIMAL(" + String(p) + "," + String(s) + "): integer "
            + String(v) + " does not fit"
        )
    return scaled


def _cast_narrow_int_to_decimal128[
    dt: DType
](
    child_col: Column[HeapRegion],
    mut out: Decimal128Array,
    p: Int,
    s: Int,
) raises:
    """Fill `out` with `child_col` (a primitive column of integer type `dt`
    narrower than 64 bits, or UINT32) cast to DECIMAL(p, s); a NULL stays
    NULL."""
    var src = child_col.as_primitive[dt]()
    for i in range(child_col.length()):
        if src.is_null(i):
            out.set_null(i)
        else:
            out.set_i128(
                i,
                _scaled_integer_to_decimal_i128(src.get(i).cast[DType.int128](), p, s),
            )


def _eval_cast_to_decimal128(child_col: Column[HeapRegion], p: Int, s: Int, batch: RecordBatch, name_hint: String) raises -> Column[HeapRegion]:
    """CAST(child AS DECIMAL(p, s)) — child is int/float/decimal/string."""
    var n = child_col.length()
    var src_at = child_col.arrow_type
    var out = Decimal128Array.allocate_nullable(n, p, s)
    if src_at == ArrowType.INT64:
        var src = child_col.as_primitive[DType.int64]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, int_to_decimal_i128(src.get(i), p, s))
    elif src_at == ArrowType.INT32:
        var src = child_col.as_primitive[DType.int32]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, int_to_decimal_i128(Int64(Int(src.get(i))), p, s))
    elif src_at == ArrowType.BOOL:
        # TRUE is 1 and FALSE is 0, as in DuckDB's `sum(<BOOLEAN>)`.
        var src = child_col.as_boolean()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(
                    i,
                    _scaled_integer_to_decimal_i128(
                        I128(1) if src.get(i) else I128(0), p, s
                    ),
                )
    elif src_at == ArrowType.INT8:
        _cast_narrow_int_to_decimal128[DType.int8](child_col, out, p, s)
    elif src_at == ArrowType.INT16:
        _cast_narrow_int_to_decimal128[DType.int16](child_col, out, p, s)
    elif src_at == ArrowType.UINT8:
        _cast_narrow_int_to_decimal128[DType.uint8](child_col, out, p, s)
    elif src_at == ArrowType.UINT16:
        _cast_narrow_int_to_decimal128[DType.uint16](child_col, out, p, s)
    elif src_at == ArrowType.UINT32:
        _cast_narrow_int_to_decimal128[DType.uint32](child_col, out, p, s)
    elif src_at == ArrowType.UINT64:
        # Past INT64's range: the value goes through the 128-bit lane, never
        # through an Int64, so 2^64 - 1 stays 2^64 - 1.
        var src = child_col.as_primitive[DType.uint64]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(
                    i,
                    _scaled_integer_to_decimal_i128(
                        src.get(i).cast[DType.int128](), p, s
                    ),
                )
    elif src_at == ArrowType.FLOAT64:
        var src = child_col.as_primitive[DType.float64]()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                var ov = float_to_decimal_i128(Float64(src.get(i)), p, s)
                if ov:
                    out.set_i128(i, ov.value())
                else:
                    out.set_null(i)
    elif src_at == ArrowType.DECIMAL128:
        var ps = _resolve_decimal_ps(child_col, batch, name_hint)
        var from_s = ps[1]
        var arr = child_col.as_decimal128()
        for i in range(n):
            if arr.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, decimal_rescale_i128(arr.get_i128(i), from_s, p, s))
    elif src_at == ArrowType.STRING:
        var src = child_col.as_string()
        for i in range(n):
            if src.is_null(i):
                out.set_null(i)
            else:
                out.set_i128(i, string_to_decimal_i128(src.get(i), p, s))
    else:
        raise Error("CAST to DECIMAL128: unsupported source type " + String(src_at))
    return Column.from_decimal128(out)


def _eval_cast_from_decimal128(child_col: Column[HeapRegion], target: DType, target_arrow: ArrowType, batch: RecordBatch, name_hint: String) raises -> Column[HeapRegion]:
    """CAST(decimal AS int/float/string)."""
    var n = child_col.length()
    var ps = _resolve_decimal_ps(child_col, batch, name_hint)
    var s = ps[1]
    var arr = child_col.as_decimal128()
    if target == DType.float64 or target_arrow == ArrowType.FLOAT64:
        var out = PrimitiveArray[DType.float64].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, decimal_to_float64(arr.get_i128(i), s))
        out.null_count = nulls
        return Column.from_primitive[DType.float64](out)
    elif target == DType.int64 or target_arrow == ArrowType.INT64:
        var out = PrimitiveArray[DType.int64].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, decimal_to_int64(arr.get_i128(i), s))
        out.null_count = nulls
        return Column.from_primitive[DType.int64](out)
    elif target == DType.int32 or target_arrow == ArrowType.INT32:
        var out = PrimitiveArray[DType.int32].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                var v64 = decimal_to_int64(arr.get_i128(i), s)
                if v64 > Int64(2147483647) or v64 < Int64(-2147483648):
                    raise Error("CAST DECIMAL128 -> INT32: value out of range")
                out.set(i, Int32(Int(v64)))
        out.null_count = nulls
        return Column.from_primitive[DType.int32](out)
    elif target == DType.float32 or target_arrow == ArrowType.FLOAT32:
        # ⭐ ADDED WITH THE RE-ADMISSION OF `REAL` AS A SQL CAST
        # TARGET. Without it `CAST(<decimal> AS REAL)` would have been the ONE
        # numeric source/target pair that still raised, and a target that works
        # for most operands and reports an internal error for one is worse than
        # one refused uniformly — the exact argument that withdrew REAL a day
        # earlier. ⚠ VIA FLOAT64 ON PURPOSE: `decimal_to_float64` is the single
        # decimal->binary-float conversion, and narrowing its correctly-rounded
        # result is what DuckDB does for `DECIMAL -> FLOAT` too.
        var out = PrimitiveArray[DType.float32].allocate_nullable(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                out.validity.value().clear(i)
                nulls += 1
            else:
                out.set(i, Float32(decimal_to_float64(arr.get_i128(i), s)))
        out.null_count = nulls
        return Column.from_primitive[DType.float32](out)
    elif target_arrow == ArrowType.STRING:
        # decimal -> string: build a StringArray of formatted values (NULL
        # rows -> empty string; the Column's validity bitmap carries NULLs).
        var values = List[String]()
        var bm = Bitmap.create_all_valid(n)
        var nulls = 0
        for i in range(n):
            if arr.is_null(i):
                values.append(String(""))
                bm.clear(i)
                nulls += 1
            else:
                values.append(decimal_to_string(arr.get_i128(i), s))
        var sa = StringArray.from_strings(values)
        var col = Column.from_string(sa)
        if nulls > 0:
            col._validity = bm^
            col._null_count = nulls
        return col^
    else:
        raise Error("CAST DECIMAL128 -> " + String(target_arrow) + ": unsupported target")


def _reduce_agg_scalar(col: Column[HeapRegion], op: UInt8) raises -> ScalarValue:
    """Reduce a fully-resident numeric Column to a single agg ScalarValue.

    The tag-12 / `EXPR_AGG_FN` typed-frame lowering of the post-agg
    scalar-broadcast shape `col == col.max` (TPC-H Q15). The caller has ALREADY
    materialized the FULL agg-breaker output into
    one resident batch (`materialize_subplan`'s POST-BREAKER FILTER arm decodes
    the breaker to a single RecordBatch BEFORE applying the predicate), so a
    reduction over `col` here is a correct GLOBAL aggregate across every group —
    mirroring the generic `DataFrame[O]` path's `optimizer_scalar_broadcast`
    eager-fold, but WITHOUT the double base-scan (the scalar is folded once over
    the resident column, not by re-executing an ungrouped Aggregate sub-plan).

    Semantics BYTE-MATCH `agg_scalar_fold.fold_scalar_agg_over_batch` (the
    monolith-free 0-key fold): a SERIAL single-accumulator reduction over the
    NON-NULL rows (value-stable — SUM matches the serial reducer bit-for-bit),
    the narrow-signed widen-fold (int-family -> I64 accumulator), and the exact
    `_agg_output_arrow` output-dtype map — int-family SUM/MIN/MAX -> INT64,
    float-family SUM/MIN/MAX -> FLOAT64, MEAN -> FLOAT64, COUNT -> INT64.

    NULL/empty contract (SQL + the generic broadcast rewrite's `scalar(batch)`):
      * COUNT (with a child) counts the NON-NULL rows -> INT64 (0 when empty).
      * SUM/MIN/MAX/MEAN over zero contributing (non-null) rows -> typed NULL
        (the empty-subquery identity; `col == NULL` then collapses every row to
        FALSE under Arrow null-compare — matching DuckDB's empty-agg semantics).

    Only the SUM/COUNT/MIN/MAX/MEAN ops over the fixed-width INT/FLOAT families
    are in-envelope. Any other op or a non-numeric input RAISES a clear error
    (this is the RAISING projection-eval path — the caller's
    `_inmem_filter_predicate_supported` gate keeps out-of-envelope predicates
    from ever reaching here)."""
    if (
        op != AGG_SUM
        and op != AGG_COUNT
        and op != AGG_MIN
        and op != AGG_MAX
        and op != AGG_MEAN
    ):
        raise Error(
            "PipelineCompiler: scalar-broadcast EXPR_AGG_FN supports only"
            " SUM/COUNT/MIN/MAX/MEAN (got op=" + String(Int(op)) + ")"
        )

    var at = col.arrow_type
    var n = col.length()

    # --- INT family (widen-fold into an I64 accumulator). ----------------------
    if (
        at == ArrowType.INT64
        or at == ArrowType.INT32
        or at == ArrowType.INT16
        or at == ArrowType.INT8
    ):
        var acc: Int64 = 0
        var count: Int = 0
        var have = False
        if at == ArrowType.INT64:
            var arr = col.as_primitive[DType.int64]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = arr.get(r)
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        else:
            # INT32 / narrow signed — widen each value to I64.
            var arr = col.as_primitive[DType.int32]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = Int64(arr.get(r))
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        if op == AGG_COUNT:
            return ScalarValue.from_int64(Int64(count))
        if count == 0:
            # Empty / all-null aggregate — typed NULL (SUM/MIN/MAX/MEAN).
            if op == AGG_MEAN:
                return ScalarValue.null(DType.float64)
            return ScalarValue.null(DType.int64)
        if op == AGG_MEAN:
            return ScalarValue.from_float(Float64(acc) / Float64(count))
        return ScalarValue.from_int64(acc)

    # --- FLOAT family (fold into an F64 accumulator). --------------------------
    elif at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32:
        var acc: Float64 = 0.0
        var count: Int = 0
        var have = False
        if at == ArrowType.FLOAT64:
            var arr = col.as_primitive[DType.float64]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = arr.get(r)
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        else:
            var arr = col.as_primitive[DType.float32]()
            for r in range(n):
                if arr.is_null(r):
                    continue
                var v = Float64(arr.get(r))
                count += 1
                if op == AGG_SUM or op == AGG_COUNT or op == AGG_MEAN:
                    acc += v
                elif op == AGG_MIN:
                    if not have or v < acc:
                        acc = v
                    have = True
                else:  # AGG_MAX
                    if not have or v > acc:
                        acc = v
                    have = True
        if op == AGG_COUNT:
            return ScalarValue.from_int64(Int64(count))
        if count == 0:
            if op == AGG_COUNT:
                return ScalarValue.from_int64(Int64(0))
            return ScalarValue.null(DType.float64)
        if op == AGG_MEAN:
            return ScalarValue.from_float(acc / Float64(count))
        return ScalarValue.from_float(acc)

    raise Error(
        "PipelineCompiler: scalar-broadcast EXPR_AGG_FN requires a fixed-width"
        " numeric (INT/FLOAT-family) input column, got type_id="
        + String(Int(at.type_id))
    )
