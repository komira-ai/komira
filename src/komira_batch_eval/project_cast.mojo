# =============================================================================
# project_cast: the projection arm for CAST
# =============================================================================
#
# One arm of `eval_column._eval_column_expr`.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.arithmetic import eval_div_scalar, eval_mul_scalar
from komira_column_kernels.cast_null import (
    eval_cast,
    eval_cast_f64_to_f32_checked,
    eval_cast_float_to_int,
)
from komira_column_kernels.compiler_helpers import clone_array_validity, int64_to_float64
from komira_kernels.cast_to_varchar_kernels import (
    cast_float32_to_string,
    cast_float64_to_string,
    cast_int32_to_string,
    cast_int64_to_string,
    cast_string_to_float32,
    cast_string_to_float64,
    cast_string_to_int32,
    cast_string_to_int64,
)
from komira_plan_expr.expr import Expr

from .column_decimal import (
    _eval_cast_from_decimal128,
    _eval_cast_to_decimal128,
    _expr_name_hint,
    _ts_unit_factor,
)
from .eval_column import _eval_column_expr
from .string_bytes import string_array_of


def _project_cast(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """The `EXPR_CAST` arm of `_eval_column_expr`."""
    var child_col = _eval_column_expr(expr.cast_child_ref(), batch)
    var target = expr.cast_target()
    var target_arrow = expr.cast_target_arrow()
    var src_at = child_col.arrow_type
    # --- DECIMAL128 casts ---
    if target_arrow == ArrowType.DECIMAL128:
        return _eval_cast_to_decimal128(child_col, expr.cast_decimal_precision(), expr.cast_decimal_scale(), batch, _expr_name_hint(expr.cast_child_ref()))
    if src_at == ArrowType.DECIMAL128:
        return _eval_cast_from_decimal128(child_col, target, target_arrow, batch, _expr_name_hint(expr.cast_child_ref()))
    # =====================================================================
    # THE NUMERIC CAST MATRIX — {I32, I64, F32, F64}, ALL 12 ORDERED PAIRS
    # =====================================================================
    #
    # ⭐ COMPLETE ON PURPOSE, AND THE GAPS ARE WHY. This ladder used to hold
    # SIX of the twelve edges. The diagonal fell through to the no-op arm at
    # the bottom, and the other SIX raised
    #
    #     PipelineCompiler: unsupported EXPR_CAST from <a> to <b>
    #
    # — an internal component name reaching a customer who wrote ordinary
    # SQL. `_sql_cast_target_arrow` had already withdrawn REAL as a TARGET
    # for exactly this, but a TARGET table cannot see a SOURCE:
    # `CAST(f32 AS BIGINT)` names only served types (BIGINT is served) and
    # still died here. ⛔ So do not "tidy" this back into
    # the six that had callers — the missing six ARE the defect, and every
    # kernel each one needs already existed (`_cmp_narrow_to_float32` above
    # has been calling `eval_cast[int64, float32]` all along).
    #
    # ⛔⛔ FLOAT -> INTEGER IS **NOT** `eval_cast`, AND THAT IS THE OTHER HALF
    # OF THIS BLOCK'S REWRITE. `eval_cast`'s SIMD `.cast[int]` truncates
    # toward zero; DuckDB v1.5.3 rounds HALF TO EVEN. The four float->int
    # edges therefore go through `eval_cast_float_to_int`, which is the only
    # spelling of that rule. See `komira_column_kernels/cast_null.mojo`.
    #
    # ⭐ AND IT ALSO CARRIES THE OVERFLOW GUARD, WHICH IS
    # WHY THESE FOUR ARMS PASS `expr.cast_is_try` AND THE OTHER EIGHT DO
    # NOT. A float source is the only side of this matrix whose value can be
    # unrepresentable in the target: before the guard, all four of
    # `CAST(1e308 AS BIGINT)`, `CAST(-1e308 AS BIGINT)`, `CAST(nan AS BIGINT)`
    # and `CAST(1e30::FLOAT AS BIGINT)` ANSWERED -9223372036854775808 with a
    # success code where DuckDB v1.5.3 raises. TRY nulls the row instead,
    # which is the same `_try` forwarding the STRING arms below carry.
    #
    # ⚠ THE INT64 -> INT32 ARM BELOW IS THE SAME DEFECT CLASS AND IS **NOT**
    # FIXED HERE — `eval_cast[int64, int32]` still truncates the high bits,
    # so `CAST(9223372036854775807 AS INTEGER)` answers -1 where DuckDB
    # raises. It is REFUSED BY NAME rather than half-done: `eval_cast` is a
    # SHARED kernel that the implicit-promotion paths (`_cmp_narrow_to_float32`
    # and friends) also call, so a raise added inside it would change
    # comparison behaviour that no cast oracle grades. Closing it needs its
    # own guarded narrowing kernel, the way the float side got one.
    # It is a registered, known refusal.
    #
    # ⭐ AND F64 -> F32 IS CHECKED :
    # a FINITE double whose float rounding is +-inf RAISES DuckDB's
    # `Conversion Error ... destination type FLOAT` (TRY: NULL) instead of
    # answering inf. `eval_cast_f64_to_f32_checked` in `cast_null.mojo`.
    #
    #          target ->    I32        I64        F32        F64
    #   source I32          no-op      eval_cast  eval_cast  eval_cast
    #          I64          eval_cast  no-op      eval_cast  int64_to_float64
    #          F32          ROUND      ROUND      no-op      eval_cast
    #          F64          ROUND      ROUND      CHECKED    no-op
    #
    # --- INT64 source ---
    if src_at == ArrowType.INT64 and target == DType.float64:
        var arr = child_col.as_primitive[DType.int64]()
        var result = int64_to_float64(arr)
        return Column.from_primitive[DType.float64](result)
    elif src_at == ArrowType.INT64 and target == DType.int32:
        var arr = child_col.as_primitive[DType.int64]()
        var result = eval_cast[DType.int64, DType.int32](arr)
        return Column.from_primitive[DType.int32](result)
    elif src_at == ArrowType.INT64 and target == DType.float32:
        var arr = child_col.as_primitive[DType.int64]()
        var result = eval_cast[DType.int64, DType.float32](arr)
        return Column.from_primitive[DType.float32](result)
    # --- INT32 source ---
    elif src_at == ArrowType.INT32 and target == DType.int64:
        var arr = child_col.as_primitive[DType.int32]()
        var result = eval_cast[DType.int32, DType.int64](arr)
        return Column.from_primitive[DType.int64](result)
    elif src_at == ArrowType.INT32 and target == DType.float64:
        var arr = child_col.as_primitive[DType.int32]()
        var result = eval_cast[DType.int32, DType.float64](arr)
        return Column.from_primitive[DType.float64](result)
    elif src_at == ArrowType.INT32 and target == DType.float32:
        var arr = child_col.as_primitive[DType.int32]()
        var result = eval_cast[DType.int32, DType.float32](arr)
        return Column.from_primitive[DType.float32](result)
    # --- FLOAT64 source. The two integer targets ROUND HALF TO EVEN. ---
    elif src_at == ArrowType.FLOAT64 and target == DType.int64:
        var arr = child_col.as_primitive[DType.float64]()
        var result = eval_cast_float_to_int[DType.float64, DType.int64](arr, expr.cast_is_try())
        return Column.from_primitive[DType.int64](result)
    elif src_at == ArrowType.FLOAT64 and target == DType.int32:
        var arr = child_col.as_primitive[DType.float64]()
        var result = eval_cast_float_to_int[DType.float64, DType.int32](arr, expr.cast_is_try())
        return Column.from_primitive[DType.int32](result)
    elif src_at == ArrowType.FLOAT64 and target == DType.float32:
        var arr = child_col.as_primitive[DType.float64]()
        var result = eval_cast_f64_to_f32_checked(arr, expr.cast_is_try())
        return Column.from_primitive[DType.float32](result)
    # --- FLOAT32 source. Same rounding rule; a SEPARATE instantiation, so a
    #     fix confined to the 64-bit source cannot be read as covering it.
    elif src_at == ArrowType.FLOAT32 and target == DType.int64:
        var arr = child_col.as_primitive[DType.float32]()
        var result = eval_cast_float_to_int[DType.float32, DType.int64](arr, expr.cast_is_try())
        return Column.from_primitive[DType.int64](result)
    elif src_at == ArrowType.FLOAT32 and target == DType.int32:
        var arr = child_col.as_primitive[DType.float32]()
        var result = eval_cast_float_to_int[DType.float32, DType.int32](arr, expr.cast_is_try())
        return Column.from_primitive[DType.int32](result)
    elif src_at == ArrowType.FLOAT32 and target == DType.float64:
        var arr = child_col.as_primitive[DType.float32]()
        var result = eval_cast[DType.float32, DType.float64](arr)
        return Column.from_primitive[DType.float64](result)
    # --- Temporal bit-reinterpret casts ---
    # date32 is physically int32, timestamp[*] is physically int64. A
    # cast between the temporal type and its underlying integer is a
    # pure reinterpret (same buffer, same null mask, only the logical
    # ArrowType tag changes) — no compute, no allocation. Relabel in
    # place.
    #
    # the reverse
    # direction (`cast(int AS date32/timestamp)`) and the timestamp-unit
    # scale conversions (`ts[ms] -> ts[us]`) wired up by using
    # `target_arrow` (the Arrow logical type carrier added by
    # `target_arrow` (the Arrow logical type carrier). Same SIMD shape as the forward
    # direction (relabel) + an `eval_mul_scalar` / `eval_div_scalar`
    # for the unit conversion.
    elif src_at == ArrowType.DATE32 and target == DType.int32:
        # forward: DATE32 -> INT32 (relabel only)
        var c = child_col^
        c.arrow_type = ArrowType.INT32
        return c^
    elif src_at == ArrowType.DATE32 and target == DType.int64:
        # ★★ DATE32 -> INT64, THE WIDENING FORWARD CAST.
        #
        # ⛔ IT IS NOT A CONVENIENCE OVER THE RELABEL ABOVE, AND THE REASON
        # IS THAT A DATE COLUMN ARRIVES HERE UNDER TWO DIFFERENT STAMPS.
        # `_resolve_temporal_arrow_type`'s docstring states the live one:
        # the parquet reader hands back a Column stamped INT32 (the
        # PHYSICAL type) while the batch SCHEMA field carries DATE32; an
        # in-memory batch, or a `CAST(x AS DATE)`, is stamped DATE32. A
        # producer that emitted `CAST(<date> AS INT32)` would therefore hit
        # the relabel above for ONE of those two shapes and fall off the
        # end of this ladder for the other — the same lowering raising on
        # half its inputs, chosen by a stamp the producer cannot see.
        #
        # Targeting INT64 makes the pair symmetric: the INT32-stamped
        # column takes the `INT32 -> int64` widen a few arms up, the
        # DATE32-stamped one takes this arm, and both answer the same
        # INT64 column. `date_diff('day', a, b)` / `date_sub` lower to
        # exactly that subtraction (`sql_binder._date_delta_days_over_
        # columns`).
        #
        # ⚠ `as_primitive[int32]` ADMITS A DATE32-STAMPED COLUMN — a DATE32
        # IS an int32 of days (`column.mojo` storage
        # compatibility) — so this is the ordinary widen, not a
        # reinterpret, and `eval_cast` PRESERVES VALIDITY. That is where
        # `date_diff(<NULL date>, x) IS NULL` comes from.
        var d64_arr = child_col.as_primitive[DType.int32]()
        var d64 = eval_cast[DType.int32, DType.int64](d64_arr)
        return Column.from_primitive[DType.int64](d64)
    elif src_at.is_timestamp() and target == DType.int64 and not target_arrow.is_timestamp():
        # forward: TIMESTAMP_* -> INT64 (relabel only). Guard:
        # target_arrow being a timestamp means a same-physical-type
        # SCALE conversion (handled below by the dedicated arm) — do
        # not pick this arm for `cast(ts[ms] AS ts[us])`.
        var c = child_col^
        c.arrow_type = ArrowType.INT64
        return c^
    elif src_at == ArrowType.INT32 and target_arrow == ArrowType.DATE32:
        # reverse: INT32 -> DATE32 (relabel only)
        var c = child_col^
        c.arrow_type = ArrowType.DATE32
        return c^
    elif src_at == ArrowType.INT64 and target_arrow.is_timestamp():
        # reverse: INT64 -> TIMESTAMP_* (relabel only — values are
        # assumed to be in the target unit; no scale).
        var c = child_col^
        c.arrow_type = target_arrow
        return c^
    elif src_at.is_timestamp() and target_arrow.is_timestamp():
        # SCALE conversion between timestamp units. Source unit from
        # src_at; target unit from target_arrow. Same-unit is a no-op.
        #
        # Validity preservation: eval_mul_scalar / eval_div_scalar return
        # non-nullable PrimitiveArray (validity not propagated by the
        # SIMD kernel). Use `clone_array_validity` to carry the input
        # null mask onto the output. Same shape as int64_to_float64 in
        # compiler_helpers.
        var factor = _ts_unit_factor(src_at, target_arrow)
        if factor == 0:
            # same-unit no-op
            var c = child_col^
            c.arrow_type = target_arrow
            return c^
        var arr = child_col.as_primitive[DType.int64]()
        if factor > 0:
            # source unit < target unit (coarser -> finer): multiply.
            var scaled = eval_mul_scalar[DType.int64](arr, Scalar[DType.int64](factor))
            clone_array_validity[DType.int64, DType.int64](arr, scaled)
            var out = Column.from_primitive[DType.int64](scaled)
            out.arrow_type = target_arrow
            return out^
        else:
            # source unit > target unit (finer -> coarser): divide.
            # Truncation toward zero (same as DuckDB).
            var scaled = eval_div_scalar[DType.int64](arr, Scalar[DType.int64](-factor))
            clone_array_validity[DType.int64, DType.int64](arr, scaled)
            var out = Column.from_primitive[DType.int64](scaled)
            out.arrow_type = target_arrow
            return out^
    # --- STRING <-> numeric ---
    # `_try` forwards the TRY_CAST flag so an
    # unparseable row yields NULL (try) vs RAISES (strict CAST).
    elif src_at == ArrowType.STRING and target == DType.int64:
        var sa = string_array_of(child_col)
        var arr = cast_string_to_int64(sa, expr.cast_is_try())
        return Column.from_primitive[DType.int64](arr)
    elif src_at == ArrowType.STRING and target == DType.int32:
        var sa = string_array_of(child_col)
        var arr = cast_string_to_int32(sa, expr.cast_is_try())
        return Column.from_primitive[DType.int32](arr)
    elif src_at == ArrowType.STRING and target == DType.float64:
        var sa = string_array_of(child_col)
        var arr = cast_string_to_float64(sa, expr.cast_is_try())
        return Column.from_primitive[DType.float64](arr)
    elif src_at == ArrowType.STRING and target == DType.float32:
        var sa = string_array_of(child_col)
        var arr = cast_string_to_float32(sa, expr.cast_is_try())
        return Column.from_primitive[DType.float32](arr)
    elif src_at == ArrowType.INT64 and target_arrow == ArrowType.STRING:
        var pa = child_col.as_primitive[DType.int64]()
        var sa = cast_int64_to_string(pa)
        return Column.from_string(sa)
    elif src_at == ArrowType.INT32 and target_arrow == ArrowType.STRING:
        var pa = child_col.as_primitive[DType.int32]()
        var sa = cast_int32_to_string(pa)
        return Column.from_string(sa)
    elif src_at == ArrowType.FLOAT64 and target_arrow == ArrowType.STRING:
        var pa = child_col.as_primitive[DType.float64]()
        var sa = cast_float64_to_string(pa)
        return Column.from_string(sa)
    elif src_at == ArrowType.FLOAT32 and target_arrow == ArrowType.STRING:
        var pa = child_col.as_primitive[DType.float32]()
        var sa = cast_float32_to_string(pa)
        return Column.from_string(sa)
    elif ArrowType.from_dtype(target) == src_at:
        # No-op cast (target physical type == source type)
        return child_col^
    else:
        raise Error(
            "PipelineCompiler: unsupported EXPR_CAST from "
            + String(src_at) + " to " + String(ArrowType.from_dtype(target))
        )
