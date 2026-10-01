# =============================================================================
# compiler_eval_case — CASE/WHEN expression evaluation (per-row branching)
# =============================================================================
#
# Split out of compiler_eval.mojo.
# Contains:
#   _eval_when_expr        — CASE WHEN entry point (Expr -> Column)
#   _run_case_overlay      — dtype-specialized forward-overlay (numeric)
#   _clone_bitmap          — deep-copy a Bitmap
#   _run_case_overlay_utf8 — Utf8 (STRING) overlay, single-pass materialization
#
# HEAP-OWNERSHIP CONTRACT (stays entirely in this file):
#   `_eval_when_expr` allocates the `cond_masks_ptr` slot array on the heap
#   (Movable-only Bitmap). `_run_case_overlay` / `_run_case_overlay_utf8`
#   own destruction of the per-slot cond masks; the caller (`_eval_when_expr`)
#   frees the heap allocation itself on normal return, and the overlay
#   helpers free it on raise (since Mojo 0.26 does not run the caller's
#   free-after-return on exception propagation). `_run_case_overlay_utf8`
#   does NOT participate in the cond_masks ownership chain beyond destroying
#   the slots — it owns its own THEN-column slot array (`then_cols_ptr`)
#   end-to-end. Do NOT split any of these four functions across files
#   without first relocating the entire contract.
#
# If a vectorized-CASE rework pushes this file
# past ~850 LOC, carve `_run_case_overlay_utf8` + `_clone_bitmap` into
# `compiler_eval_case_utf8.mojo` (it owns its own slot array; clean carve).
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_core.arrow.schema import RecordBatch
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.bitmap_ops import select_into, blend_into, bitmap_blend_into
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import Expr
from komira_core.eval.int_overflow import is_int_overflow_error

from .compiler_eval_dict import _densify_dict_column
from .compiler_eval_predicate import _eval_predicate
from .compiler_eval_column import _eval_column_expr
from .arm_rows import batch_nulled_outside


# =============================================================================
# ⛔ A CASE ARM IS EVALUATED ONLY OVER THE ROWS IT ANSWERS
# =============================================================================
#
# Each THEN / ELSE arm is computed over the WHOLE batch and blended, which is
# exact for an arm that cannot RAISE. Integer `+ - *` can now (DuckDB's
# `Out of Range Error: Overflow in ...`), and DuckDB evaluates an arm only over
# the rows its WHEN selects. So an arm that raises an OVERFLOW is re-evaluated
# over the rows it answers — `arm_rows.batch_nulled_outside`, whose header has
# the measurement and the argument. The fast path is unchanged.

def _eval_case_arm(
    imm e: Expr, batch: RecordBatch, imm sel: Bitmap[HeapRegion]
) raises -> Column[HeapRegion]:
    """Evaluate one CASE arm; on an integer OVERFLOW, re-evaluate it over only
    the rows `sel` says it answers (see the block above)."""
    try:
        return _eval_column_expr(e, batch)
    except err:
        if not is_int_overflow_error(String(err)):
            raise err^
    return _eval_column_expr(e, batch_nulled_outside(batch, sel))


# =============================================================================
# CASE/WHEN evaluation — per-row branching
# =============================================================================


def _eval_when_expr(expr: Expr, batch: RecordBatch) raises -> Column[HeapRegion]:
    """Evaluate a CASE WHEN ... THEN ... ELSE ... expression (column-level).

    Algorithm (forward-overlay with `remaining` tracking):

      1. Evaluate all N condition masks upfront. NULL conditions fall through
         (treated as false) by ANDing the cond's data bitmap with its
         validity bitmap when one exists.
      2. Evaluate the default/ELSE column and initialize the result buffer
         as a copy of it (plus its validity, if present).
      3. Track a `remaining` Bitmap (initially all-valid) = rows not yet
         claimed by any prior WHEN.
      4. For each case i (forward):
         - effective_i = cond_mask_i AND remaining   (Bitmap.and_)
         - select_into[dtype]: for each row where effective_i[r], copy
           then_i.data[r] into result.data[r]. This is SIMD-vectorized.
         - Merge validity bytewise: rows claimed by effective_i take their
           validity from THEN (or all-valid if THEN is non-nullable).
         - remaining = remaining AND NOT cond_mask_i   (Bitmap.and_not)
      5. Wrap the result buffer + merged validity into a PrimitiveArray and
         Column.from_primitive.

    Why forward (vs a reverse overlay): `and_` and `and_not` exist as
    SIMD primitives in bitmap.mojo, but `or_` does not. The `remaining`-
    tracking pattern expresses "first match wins" using only AND / AND-NOT,
    avoiding the need for bitmap OR. Rows are written at most once, so
    iteration order does not affect correctness.

    Currently supports Int64 and Float64 output types. Utf8 is Phase 1b
    (variable-width offsets).

    Ownership note: `cond_masks_ptr` and `cond_validity_ptr` are heap-
    allocated slots for Movable-only Bitmap. The initialization loop is
    exception-safe: if any _eval_predicate call raises, already-initialized
    slots are destroyed and the heap memory is freed before re-raising.
    THEN columns are evaluated one at a time inside the main overlay loop
    (not upfront) — they live on the stack and are dropped at end of
    iteration, which keeps peak memory O(N_cases * bitmap_bytes) rather
    than O(N_cases * batch_bytes).
    """
    from std.memory import alloc as _alloc

    var num_rows = batch.num_rows()
    var num_cases = len(expr._when.value().cases)

    if num_rows == 0:
        # densify here too, or a CASE over a dictionary column
        # would report DICTIONARY for an EMPTY morsel and STRING for every
        # other one — a per-batch output type, which the sink above binds once.
        var default_col = _densify_dict_column(
            _eval_column_expr(expr._when.value().default[], batch)
        )
        return default_col^

    # ----- Step 1: evaluate all N condition masks upfront ----------------
    # We keep two parallel heap arrays: one for the effective cond bitmap
    # (data AND validity), and a sentinel count for structured cleanup.
    var cond_masks_ptr = _alloc[Bitmap[HeapRegion]](num_cases)
    var init_count = 0
    try:
        for i in range(num_cases):
            var cond_ba = _eval_predicate(expr._when.value().cases[i].condition[], batch)
            # NULL-cond-falls-through: AND data with validity (if present).
            # If no validity, the data bitmap already encodes "false for null-ish"
            # from _eval_predicate's construction.
            if cond_ba.validity:
                var effective = cond_ba.data.and_(cond_ba.validity.value())
                (cond_masks_ptr + i).unsafe_write(effective^)
            else:
                # Mojo 0.26 forbids partial-move out of a struct field, so
                # we clone the data bitmap rather than moving `cond_ba.data`
                # out of BooleanArray. Cost: one memcpy of ceil(num_rows/8) bytes
                # per case, negligible vs per-row evaluation.
                var cloned = _clone_bitmap(cond_ba.data)
                (cond_masks_ptr + i).unsafe_write(cloned^)
            init_count += 1
    except e:
        # Leak-safe cleanup: destroy already-initialized slots then free.
        for j in range(init_count):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        raise e^

    # ----- Step 2: evaluate default/ELSE column --------------------------
    #
    # `out_type` is read
    # off THIS column, so a DICTIONARY ELSE refused the WHOLE expression at the
    # ladder below ("only supports INT64, FLOAT64, and STRING output, got
    # dictionary") before any THEN arm was looked at. Densifying here is what
    # makes `CASE WHEN c THEN 'x' ELSE referer END` a STRING case rather than
    # an unsupported one. `_densify_dict_column` is a NO-OP pass-through for
    # every other type, so the numeric arms are byte-identical.
    var default_col: Column[HeapRegion]
    try:
        # The ELSE arm's selection: the rows NO WHEN claims. Eager, because it
        # is num_cases SIMD bitmap AND-NOTs over num_rows/8 bytes — noise next
        # to evaluating any arm — and computing it lazily would mean handing
        # the slot pointer to a helper.
        var else_sel = Bitmap.create_all_valid(num_rows)
        for i in range(num_cases):
            else_sel = else_sel.and_not((cond_masks_ptr + i)[])
        default_col = _densify_dict_column(
            _eval_case_arm(expr._when.value().default[], batch, else_sel)
        )
    except e:
        for j in range(num_cases):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        raise e^

    # Determine output type. The reference rule uses the first THEN clause; if no cases,
    # the default. We use `default_col.arrow_type` in Phase 1a because the
    # dtype guard inside `_run_case_overlay` will enforce that every THEN arm
    # agrees with `out_type`, which is equivalent to "all branches share type"
    # — the only shape Phase 1a supports.
    #
    # TODO(phase1b): the reference rule derives `out_type` from the FIRST THEN arm, not the
    # default. This matters when branches widen (e.g. Int64 THEN + Float64
    # ELSE should promote to Float64). Widening + type coercion lands with
    # Utf8 support. Until then, all branches must share a single dtype.
    var out_type: ArrowType = default_col.arrow_type

    # ----- Step 3: dispatch on out_type ----------------------------------
    # Phase 1a supports INT64/FLOAT64 via column-overlay (SIMD select_into).
    # Phase 1b adds STRING via single-pass materialization (variable-width).
    if (
        out_type != ArrowType.INT64
        and out_type != ArrowType.FLOAT64
        and out_type != ArrowType.STRING
    ):
        for i in range(num_cases):
            (cond_masks_ptr + i).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        raise Error(
            "PipelineCompiler: CASE/WHEN only supports INT64, FLOAT64, and STRING output, got "
            + String(out_type)
        )

    # ----- Binary-CASE fast path (Sub-1) ---------------------------------
    # CASE WHEN cond THEN x ELSE y END with INT64 or FLOAT64 output: single
    # SIMD blend pass over data + single SIMD u64 pass over validity.
    # Replaces 2 wasted bitmap ops (AND with all-valid `remaining`,
    # AND-NOT computing never-read new `remaining`) + scalar bytewise
    # validity merge.
    if num_cases == 1 and (out_type == ArrowType.INT64 or out_type == ArrowType.FLOAT64):
        # Need to validate the THEN arm's type matches out_type BEFORE moving
        # cond_mask out of the slot (so on type-mismatch we clean up normally).
        # Cheap check: evaluate THEN here. If types match, hand it to the
        # vectorized binary. If not, fall through to the overlay's existing
        # error handling.
        var then_col_probe: Column[HeapRegion]
        try:
            then_col_probe = _eval_case_arm(
                expr._when.value().cases[0].result[], batch, (cond_masks_ptr + 0)[]
            )
        except e:
            (cond_masks_ptr + 0).unsafe_deinit_pointee()
            cond_masks_ptr.free()
            raise e^
        if then_col_probe.arrow_type == out_type:
            # Move cond mask out of slot 0, free the heap, and dispatch.
            var cond_mask = (cond_masks_ptr + 0).take_pointee()
            cond_masks_ptr.free()
            var result: Column[HeapRegion]
            if out_type == ArrowType.INT64:
                result = _eval_case_vectorized_binary[DType.int64](
                    num_rows, cond_mask^, then_col_probe^, default_col^,
                )
            else:
                result = _eval_case_vectorized_binary[DType.float64](
                    num_rows, cond_mask^, then_col_probe^, default_col^,
                )
            return result^
        # Type mismatch -- fall through. We've already consumed the THEN col
        # for the probe, so we have to drop it (Mojo will run its destructor).
        # The overlay path re-evaluates THEN inside its loop body, so this is
        # benign (correctness preserved; we just paid one extra eval on the
        # type-mismatch error path, which raises immediately anyway).
        # NOTE: then_col_probe goes out of scope and drops here.

    # Build the result PrimitiveArray (or StringArray) by copying `default_col`
    # then overlaying. The three arms differ in layout; we dispatch on dtype.
    var result: Column[HeapRegion]
    if out_type == ArrowType.INT64:
        result = _run_case_overlay[DType.int64](
            num_rows, num_cases, cond_masks_ptr, default_col^, expr, batch
        )
    elif out_type == ArrowType.FLOAT64:
        result = _run_case_overlay[DType.float64](
            num_rows, num_cases, cond_masks_ptr, default_col^, expr, batch
        )
    else:
        # STRING: variable-width, single-pass materialization.
        result = _run_case_overlay_utf8(
            num_rows, num_cases, cond_masks_ptr, default_col^, expr, batch
        )

    # cond_masks_ptr slots were destroyed inside the overlay helper; free the heap.
    cond_masks_ptr.free()
    return result^


def _run_case_overlay[
    dtype: DType,
    origin: Origin[mut=True],
](
    num_rows: Int,
    num_cases: Int,
    cond_masks_ptr: UnsafePointer[Bitmap[HeapRegion], origin],
    var default_col: Column[HeapRegion],
    expr: Expr,
    batch: RecordBatch,
) raises -> Column[HeapRegion]:
    """Dtype-specialized forward-overlay for fixed-width numeric output.

    Owns destruction of the `cond_masks_ptr` slots (but NOT the heap ptr —
    caller frees that). Consumes `default_col`.

    SIMD overlay path uses select_into[dtype] from bitmap_ops.
    Validity merge is bytewise scalar (cheap: 1 byte per 8 data rows).
    """
    # Allocate output PrimitiveArray *with* a validity bitmap upfront (nullable
    # allocation starts all-valid). We merge validity in place directly into
    # `out.validity.value.buffer` as we overlay each case — this avoids the
    # Mojo 0.26 partial-move restriction on PrimitiveArray.data at the end.
    var out = PrimitiveArray[dtype].allocate_nullable(num_rows)
    # `out` and `default_col._data` are read and written through the
    # origin-tied `view_{mut,ro} +
    # _unsafe_ptr + bitcast` pattern. SAFETY: `out_view` pins
    # `out.data`'s mutable borrow; `default_view` pins
    # `default_col._data`'s read borrow. Both live across the memcpy.
    var out_view = out.view_mut()
    var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    comptime elem_size = size_of[Scalar[dtype]]()
    var default_view = default_col._data.view_ro()
    var default_ptr = default_view._unsafe_ptr().bitcast[Scalar[dtype]]()
    unsafe_memcpy(
        dest=out_ptr.bitcast[UInt8](),
        src=default_ptr.bitcast[UInt8](),
        count=num_rows * elem_size,
    )

    # Seed out.validity from default_col: if default has validity, copy it in;
    # otherwise leave the all-valid bitmap from allocate_nullable untouched.
    var any_nulls_possible = False
    if default_col._validity:
        any_nulls_possible = True
        var n_bytes_def = (num_rows + 7) >> 3
        if n_bytes_def > 0:
            # migrate MmapAlignedBuffer
            # `_typed_ptr_{mut,ro}[DType.uint8]` onto origin-tied
            # `view_{mut,ro} + _unsafe_ptr + bitcast`. SAFETY: both
            # validity buffers outlive the memcpy via parent Column's
            # outer borrow; both views drop at statement end.
            var out_v_view = out.validity.value().buffer.view_mut()
            var def_v_view = default_col._validity.value().buffer.view_ro()
            unsafe_memcpy(
                dest=out_v_view._unsafe_ptr().bitcast[Scalar[DType.uint8]](),
                src=def_v_view._unsafe_ptr().bitcast[Scalar[DType.uint8]](),
                count=n_bytes_def,
            )

    # `remaining` tracks rows not yet claimed by a prior WHEN.
    var remaining = Bitmap.create_all_valid(num_rows)

    # ----- Step 4: forward overlay loop ----------------------------------
    # Leak-safe: every call inside the loop body (`_eval_column_expr`,
    # `Bitmap.and_`, `select_into`, `Bitmap.and_not`, `_data._unsafe_data_ptr`)
    # can raise. If any do, slots `[i, num_cases)` still hold live Bitmaps that
    # the caller does NOT know to free (caller only owns the heap ptr, not
    # the per-slot destructors). We catch, destroy the tail, and re-raise.
    # Pattern mirrors the upfront-init cleanup in `_eval_when_expr`.
    var overlay_i: Int
    try:
        for i in range(num_cases):
            overlay_i = i
            # effective_i = cond_mask_i AND remaining — computed BEFORE the arm,
            # because it is the arm's selection if the arm overflows
            # (`_eval_case_arm`).
            var cond_mask_ref = cond_masks_ptr + i
            var effective = cond_mask_ref[].and_(remaining)
            # Evaluate THEN column for this case (inline, not upfront — keeps
            # peak memory O(cases * bitmap) instead of O(cases * batch)).
            var then_col = _eval_case_arm(
                expr._when.value().cases[i].result[], batch, effective
            )

            # Dtype guard: reinterpreting bytes via bitcast[Scalar[dtype]] would
            # be a silent correctness bug if THEN arm evaluates to a different
            # type (e.g. Int32 / Utf8). We check arrow_type — Phase 1a requires
            # all branches share `dtype`. Phase 1b may relax this for widening.
            var expected_arrow = ArrowType.from_dtype(dtype)
            if then_col.arrow_type != expected_arrow:
                raise Error(
                    "PipelineCompiler: CASE/WHEN THEN type mismatch at case "
                    + String(i)
                    + ": expected "
                    + String(expected_arrow)
                    + ", got "
                    + String(then_col.arrow_type)
                )


            # Overlay data (SIMD): for each row where effective[r], out[r] = then[r].
            # Gap6 Cluster B: select_into now takes MmapAlignedBuffer refs
            # rather than wildcard-origin pointers -- liveness is tracked
            # against the caller's buffers via refs.
            select_into[dtype](out.data, then_col._data, effective, num_rows)

            # Merge validity bytewise. Two cases:
            #   THEN has validity  -> out_v = (out_v & ~eff) | (then_v & eff)
            #   THEN is all-valid  -> out_v = out_v | eff   (effective rows become valid)
            #
            # SAFETY: `res_v_ptr` is valid only for this iteration — `out` is
            # local and `out.validity` is not reassigned, but future refactors
            # must NOT hoist this pointer outside the loop because Mojo may
            # invalidate it under move semantics. Recompute per-iteration.
            var n_bytes = (num_rows + 7) >> 3
            # migrate MmapAlignedBuffer
            # `_typed_ptr_{mut,ro}[DType.uint8]` onto origin-tied
            # `view_{mut,ro} + _unsafe_ptr + bitcast`. SAFETY: out /
            # effective / then_col all live for this iteration; the
            # `*_view` locals pin each buffer's borrow across the inner
            # bytewise merge loop until end-of-iter scope drop.
            var res_v_view = out.validity.value().buffer.view_mut()
            var res_v_ptr = res_v_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
            var eff_view = effective.buffer.view_ro()
            var eff_ptr = eff_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
            if then_col._validity:
                any_nulls_possible = True
                var then_v_view = then_col._validity.value().buffer.view_ro()
                var then_v_ptr = then_v_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
                for b in range(n_bytes):
                    var eb = (eff_ptr + b)[]
                    var rb = (res_v_ptr + b)[]
                    var tb = (then_v_ptr + b)[]
                    (res_v_ptr + b)[] = (rb & ~eb) | (tb & eb)
            else:
                for b in range(n_bytes):
                    (res_v_ptr + b)[] = (res_v_ptr + b)[] | (eff_ptr + b)[]

            # remaining = remaining AND NOT cond_mask_i
            var new_remaining = remaining.and_not(cond_mask_ref[])
            remaining = new_remaining^

            # Destroy this case's cond mask now that we're done with it.
            # NOTE: `and_` takes a ref, doesn't consume. We destroy explicitly.
            (cond_masks_ptr + i).unsafe_deinit_pointee()
    except e:
        # Destroy tail slots [overlay_i, num_cases) — the slot at overlay_i was
        # still live at the point of raise (destroy_pointee only runs at end of
        # iteration), and slots after it were never touched in this call.
        # Also free the heap ptr here because on raise the caller's
        # `cond_masks_ptr.free` line is skipped by exception propagation.
        for j in range(overlay_i, num_cases):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        raise e^

    # ----- Step 5: build final Column ------------------------------------
    # `out` already carries a validity bitmap (seeded from default_col and
    # merged across all WHEN/THEN overlays). Update its null_count so that
    # downstream consumers see the correct count, then wrap as a Column.
    #
    # If NO branch (default or any THEN) was nullable, we know all rows are
    # valid — Column.from_primitive still copies the all-ones validity which
    # is harmless but wastes ceil(num_rows/8) bytes. Acceptable for Phase 1a.
    if any_nulls_possible:
        out.null_count = out.validity.value().null_count()
    else:
        out.null_count = 0
    return Column.from_primitive[dtype](out)


@always_inline
def _clone_bitmap(src: Bitmap[HeapRegion]) -> Bitmap[HeapRegion]:
    """Deep-copy a Bitmap (byte-for-byte). Used to initialize result validity
    from the default column without consuming the default's bitmap."""
    var dst = Bitmap.create(src.length)
    var num_bytes = (src.length + 7) >> 3
    if num_bytes > 0:
        # migrate MmapAlignedBuffer
        # `_typed_ptr_{mut,ro}[DType.uint8]` onto origin-tied
        # `view_{mut,ro} + _unsafe_ptr + bitcast`. SAFETY: `dst.buffer`
        # is locally owned; `src.buffer` is the function-arg borrow,
        # both live across the memcpy; views drop at end of statement.
        var dst_view = dst.buffer.view_mut()
        var src_view = src.buffer.view_ro()
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr().bitcast[Scalar[DType.uint8]](),
            src=src_view._unsafe_ptr().bitcast[Scalar[DType.uint8]](),
            count=num_bytes,
        )
        dst.buffer.set_length(num_bytes)

    return dst^


def _eval_case_vectorized_binary[
    dtype: DType,
](
    num_rows: Int,
    var cond_mask: Bitmap[HeapRegion],
    var then_col: Column[HeapRegion],
    var default_col: Column[HeapRegion],
) raises -> Column[HeapRegion]:
    """Vectorized binary-CASE blend: CASE WHEN cond THEN x ELSE y END.

    Single-pass SIMD blend over the data buffer + single-pass SIMD u64
    blend over the validity bitmap. Replaces the 2-pass overlay shape
    (`memcpy(out, else_data); select_into(out, then_data, cond)` +
    scalar bytewise validity merge) used by `_run_case_overlay` when
    only one WHEN clause is present.

    Args:
        num_rows:    Row count of the batch.
        cond_mask:   Effective condition bitmap (NULL-cond-falls-through
                     already applied -- caller has ANDed cond.data with
                     cond.validity if present). Consumed.
        then_col:    THEN-branch column. arrow_type guaranteed by caller.
                     Consumed.
        default_col: ELSE-branch column. arrow_type guaranteed by caller.
                     Consumed.

    Returns: Column of arrow_type matching dtype, length=num_rows.

    The output is always nullable (validity bitmap allocated). Any branch
    with no validity bitmap is treated as "all-valid" via an inline
    materialization of an all-valid Bitmap (cheap: O(num_rows/8) bytes
    of memset).
    """
    # Allocate output PrimitiveArray with validity (all-valid seed).
    var out = PrimitiveArray[dtype].allocate_nullable(num_rows)

    # ----- Step 1: SIMD blend the data buffer ----------------------------
    # out.data[r] = cond_mask[r] ? then_col._data[r] : default_col._data[r]
    blend_into[dtype](
        out.data,
        then_col._data,
        default_col._data,
        cond_mask,
        num_rows,
    )

    # ----- Step 2: SIMD blend the validity bitmap ------------------------
    # 4 cases on (then has validity?, else has validity?). We canonicalize
    # via inline all-valid Bitmap materialization for the missing side.
    # `out` was allocated with an all-valid bitmap (from allocate_nullable),
    # so we always merge INTO `out.validity` directly.
    var has_then_v = then_col._validity.__bool__()
    var has_else_v = default_col._validity.__bool__()
    var any_nulls = False

    if has_then_v or has_else_v:
        any_nulls = True
        # Materialize the missing side as all-valid (cheap; <=8KB at 64K rows).
        # We always pass the cond_mask itself (its buffer) as the per-bit
        # selector. The blend kernel computes (cond & then_v) | (~cond & else_v).
        if has_then_v and has_else_v:
            bitmap_blend_into(
                out.validity.value().buffer,
                cond_mask.buffer,
                then_col._validity.value().buffer,
                default_col._validity.value().buffer,
                num_rows,
            )
        elif has_then_v:
            var all_valid_else = Bitmap.create_all_valid(num_rows)
            bitmap_blend_into(
                out.validity.value().buffer,
                cond_mask.buffer,
                then_col._validity.value().buffer,
                all_valid_else.buffer,
                num_rows,
            )
        else:
            # has_else_v only
            var all_valid_then = Bitmap.create_all_valid(num_rows)
            bitmap_blend_into(
                out.validity.value().buffer,
                cond_mask.buffer,
                all_valid_then.buffer,
                default_col._validity.value().buffer,
                num_rows,
            )

    # ----- Step 3: finalize null_count and wrap -------------------------
    if any_nulls:
        out.null_count = out.validity.value().null_count()
    else:
        out.null_count = 0

    return Column.from_primitive[dtype](out)


def _run_case_overlay_utf8[
    origin: Origin[mut=True]
](
    num_rows: Int,
    num_cases: Int,
    cond_masks_ptr: UnsafePointer[Bitmap[HeapRegion], origin],
    var default_col: Column[HeapRegion],
    expr: Expr,
    batch: RecordBatch,
) raises -> Column[HeapRegion]:
    """Utf8 (STRING) overlay for CASE/WHEN — single-pass materialization.

    Algorithm (single pass, like the generic `zip` path for variable-width
    strings):

      1. Pre-evaluate all N THEN columns into a heap-backed List[Column].
         Unlike the numeric overlay where each THEN is evaluated inline
         during iteration (keeping peak memory O(cases * bitmap)), string
         output needs random access per-row to every branch's bytes, so we
         accept O(cases * string_payload) peak here.
      2. Compute a per-row `winner` array (one UInt8 per row) via a bitmap
         pass:
           remaining = all_valid
           for i in [0, num_cases):
               effective_i = cond_i AND remaining
               for each r where effective_i[r]=1: winner[r] = i
               remaining = remaining AND NOT cond_i
           rows still remaining get winner[r] = num_cases (default).
         Per-row branching avoids a second pass — cheaper than allocating
         N+1 masked copies of the full string columns.
      3. Walk rows once: for each r, copy bytes from the winner branch
         (or default) into a growing output data buffer, write the
         cumulative offset, and set validity = winner's validity at r.

    Ownership contract: on return (normal or raise), all `num_cases` slots
    at `cond_masks_ptr` have been destroyed. The heap allocation itself is
    freed by the caller on normal return; on raise, we free it here since
    Mojo 0.26 does not run the caller's free-after-return on exception
    propagation. Matches the contract from `_run_case_overlay`.

    SAFETY: String columns in this codebase assume `_offset = 0` and
    `offsets[0] = 0` / `offsets[N] = data_length`. `_copy_column` produces
    columns that satisfy this. `_eval_column_expr` for `ColRef` returns
    `_copy_column` output so the contract holds for all Utf8 THEN arms
    supported in Phase 1b (col-ref only; other Utf8-producing expression
    shapes are a future extension).
    """
    from std.memory import alloc as _alloc

    # ----- Pre-check: default must be Utf8 -------------------------------
    # (The caller has already verified out_type == STRING via default_col,
    # so this is a defensive check mirroring the numeric arm's dtype guard.)
    if default_col.arrow_type != ArrowType.STRING:
        for j in range(num_cases):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        raise Error(
            "PipelineCompiler: CASE/WHEN Utf8 arm expected STRING default, got "
            + String(default_col.arrow_type)
        )

    # ----- Step 1: pre-evaluate all THEN columns -------------------------
    # Heap-allocated slots for Movable-only Column. Exception-safe init
    # loop mirrors `_eval_when_expr`'s upfront cond-mask init pattern: if
    # a THEN evaluation raises at case i, destroy slots [0, i) and free
    # the heap ptr + also destroy the cond masks the caller owns, so on
    # raise the caller owns nothing.
    # Allocate (num_cases + 1) slots: [0..num_cases) for THEN cols, slot
    # `num_cases` for the default. This lets the materialization pass
    # index uniformly by `winner[r]` (which is num_cases for default rows)
    # without needing a separate code path for the default.
    var then_cols_ptr = _alloc[Column[HeapRegion]](num_cases + 1)
    var then_init = 0
    try:
        for i in range(num_cases):
            # THE ClickBench Q39 SITE. The grouped parquet agg leaf has a
            # `MapOp`
            # tail, so a computed group key is now evaluated over the leaf's
            # own decoded batch, which carries the FILE's native encoding. A
            # low-cardinality BYTE_ARRAY column (`referer`) therefore arrives
            # DICTIONARY where the route it replaced presented a densified
            # STRING, and ClickBench Q39 — `CASE WHEN (search_engine_id = 0 AND
            # adv_engine_id = 0) THEN referer ELSE '' END` — stopped executing
            # with the guard below. `_densify_dict_column` resolves the codes
            # to bytes and carries the validity; it is a NO-OP for a column
            # that is already STRING.
            #
            # ⛔ IT DOES NOT WEAKEN THE GUARD. A THEN arm that is genuinely not
            # string-shaped (INT64 under a STRING default) still raises below.
            var tc = _densify_dict_column(
                _eval_column_expr(expr._when.value().cases[i].result[], batch)
            )
            # Dtype guard: all THEN arms must agree with out_type == STRING.
            # Without this, a ByteArray reinterpret is a silent correctness bug.
            if tc.arrow_type != ArrowType.STRING:
                raise Error(
                    "PipelineCompiler: CASE/WHEN Utf8 THEN type mismatch at case "
                    + String(i)
                    + ": expected STRING, got "
                    + String(tc.arrow_type)
                )
            (then_cols_ptr + i).unsafe_write(tc^)
            then_init += 1
        # Slot num_cases: default column. Consumes `default_col`.
        (then_cols_ptr + num_cases).unsafe_write(default_col^)
        then_init += 1
    except e:
        for j in range(then_init):
            (then_cols_ptr + j).unsafe_deinit_pointee()
        then_cols_ptr.free()
        for j in range(num_cases):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        raise e^

    # ----- Step 2: compute per-row winner byte array ---------------------
    # winner[r] in [0, num_cases) = THEN index, winner[r] = num_cases = default.
    # Using UInt8 caps num_cases at 255, which is plenty — real CASE
    # expressions with > 255 branches are vanishingly rare. We assert below.
    if num_cases > 255:
        # Structured cleanup: destroy THEN cols (incl default slot) + cond masks, free both heaps.
        for j in range(num_cases + 1):
            (then_cols_ptr + j).unsafe_deinit_pointee()
        for j in range(num_cases):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        then_cols_ptr.free()
        cond_masks_ptr.free()
        raise Error(
            "PipelineCompiler: CASE/WHEN Utf8 arm supports at most 255 WHEN branches; got "
            + String(num_cases)
        )

    var winner_ptr = _alloc[UInt8](num_rows)
    # Initialize winner[r] = num_cases (default sentinel).
    var default_sentinel = UInt8(num_cases)
    for r in range(num_rows):
        (winner_ptr + r).unsafe_write(default_sentinel)

    var winner_i = 0
    try:
        var remaining = Bitmap.create_all_valid(num_rows)
        for i in range(num_cases):
            winner_i = i
            var cond_mask_ref = cond_masks_ptr + i
            var effective = cond_mask_ref[].and_(remaining)
            # Scalar pass: for each bit set in `effective`, stamp winner[r] = i.
            # (SIMD stamping of a non-packed byte array from a bitmap is a
            # future optimization; the walk is O(N) and typically dwarfed
            # by string byte-copying in Step 3.)
            # migrate MmapAlignedBuffer
            # `_typed_ptr_ro[DType.uint8]` onto origin-tied
            # `view_ro + _unsafe_ptr + bitcast`. SAFETY: `effective`
            # lives for this iter; `eff_view` ByteView pins the buffer
            # borrow across the bit-stamp loop until end-of-iter drop.
            var eff_view = effective.buffer.view_ro()
            var eff_ptr = eff_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
            var n_bytes = (num_rows + 7) >> 3
            var r_base = 0
            for b in range(n_bytes):
                var byte = (eff_ptr + b)[]
                if byte != 0:
                    var upper = min(8, num_rows - r_base)
                    for bit in range(upper):
                        if (byte >> UInt8(bit)) & 1:
                            (winner_ptr + r_base + bit)[] = UInt8(i)
                r_base += 8

            var new_remaining = remaining.and_not(cond_mask_ref[])
            remaining = new_remaining^
            # Destroy this case's cond mask now that we're done with it.
            (cond_masks_ptr + i).unsafe_deinit_pointee()
    except e:
        # Tail cleanup: cond masks [winner_i, num_cases) still live.
        for j in range(winner_i, num_cases):
            (cond_masks_ptr + j).unsafe_deinit_pointee()
        cond_masks_ptr.free()
        # THEN cols + default slot are all live (we fully initialized above).
        for j in range(num_cases + 1):
            (then_cols_ptr + j).unsafe_deinit_pointee()
        then_cols_ptr.free()
        winner_ptr.free()
        raise e^

    # ----- Step 3: single-pass materialization ---------------------------
    # Compute total output bytes by summing per-row lengths from the winning
    # branch. Then allocate data + offsets + validity and fill.
    #
    # Two-pass variant (size then copy) avoids a geometric-growth realloc
    # loop. On a string-heavy pipeline (q12-shape), this is straightforward
    # and avoids MmapAlignedBuffer.reserve churn.

    comptime int32_size = size_of[Int32]()

    # Wrap Step 3 in try/except so we still clean up THEN cols + winner_ptr
    # on raise (e.g. overflow in offset arithmetic).
    var out_col: Column[HeapRegion]
    try:
        # --- Size pass ---
        # winner[r] in [0, num_cases] — slot `num_cases` holds the default,
        # so a uniform index into `then_cols_ptr` covers both paths.
        var total_bytes = 0
        for r in range(num_rows):
            var w = Int((winner_ptr + r)[])
            var src_col_ptr = then_cols_ptr + w
            # If source row is null, contribute zero bytes. The offsets
            # entry still advances by zero so offsets[r+1] == offsets[r].
            var is_null = False
            if src_col_ptr[]._validity:
                is_null = not src_col_ptr[]._validity.value().test(r)
            if not is_null:
                # migrate MmapAlignedBuffer
                # `_typed_ptr_ro[DType.int32]` onto origin-tied
                # `view_ro + _unsafe_ptr + bitcast`. SAFETY: `_offsets`
                # buffer is owned by `src_col_ptr[]` which is the
                # `then_cols_ptr` slot — caller holds it alive across
                # the size pass. `off_view` ByteView pins the buffer's
                # borrow across the two reads + drops at iter end.
                var off_view = src_col_ptr[]._offsets.value().view_ro()
                var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                var s = Int((off_ptr + r)[])
                var e2 = Int((off_ptr + r + 1)[])
                total_bytes += (e2 - s)

        # --- Allocate output buffers ---
        var offsets_buf = OwnedAlignedBuffer((num_rows + 1) * int32_size)
        # migrate MmapAlignedBuffer
        # `_typed_ptr_mut[DType.int32]` onto origin-tied
        # `view_mut + _unsafe_ptr + bitcast`. SAFETY: `offsets_buf`
        # is locally-owned and mutated only via `offsets_out` through
        # the copy pass; `offsets_view` ByteView pins the buffer's
        # mutable borrow across the entire copy loop until `offsets_buf^`
        # moves into the Column ctor at the bottom of the try.
        var offsets_view = offsets_buf.view_mut()
        var offsets_out = offsets_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        (offsets_out + 0).unsafe_write(Int32(0))

        var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
        # migrate MmapAlignedBuffer
        # `_typed_ptr_mut[DType.uint8]` onto origin-tied
        # `view_mut + _unsafe_ptr + bitcast`. SAFETY: same as
        # `offsets_view` above — `data_view` pins `data_buf`'s borrow
        # across the copy loop.
        var data_view = data_buf.view_mut()
        var data_out = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()

        # Output validity is always allocated (nullable) because any branch
        # could contribute NULL. We start all-valid and clear per row.
        var out_validity = Bitmap.create_all_valid(num_rows)
        var any_nulls = False

        # --- Copy pass ---
        var offset = 0
        for r in range(num_rows):
            var w = Int((winner_ptr + r)[])
            var src_col_ptr = then_cols_ptr + w

            var is_null = False
            if src_col_ptr[]._validity:
                is_null = not src_col_ptr[]._validity.value().test(r)

            if is_null:
                out_validity.clear(r)
                any_nulls = True
                # offsets advance by 0 — offsets[r+1] = offset (unchanged)
            else:
                # migrate MmapAlignedBuffer
                # `_typed_ptr_ro[DType.int32]` (offsets) and
                # `_typed_ptr_ro[DType.uint8]` (data) onto origin-tied
                # `view_ro + _unsafe_ptr + bitcast`. SAFETY: `_offsets`
                # and `_data` are owned by `src_col_ptr[]` (the
                # `then_cols_ptr` slot) which the caller holds alive
                # across the copy pass; both views drop at iter end.
                var off_view = src_col_ptr[]._offsets.value().view_ro()
                var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                var s = Int((off_ptr + r)[])
                var e2 = Int((off_ptr + r + 1)[])
                var span = e2 - s
                if span > 0:
                    var src_data_view = src_col_ptr[]._data.view_ro()
                    var src_data_ptr = src_data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
                    unsafe_memcpy(
                        dest=data_out + offset,
                        src=src_data_ptr + s,
                        count=span,
                    )
                offset += span
            (offsets_out + r + 1).unsafe_write(Int32(offset))

        offsets_buf.set_length(Int64((num_rows + 1) * int32_size))

        data_buf.set_length(Int64(total_bytes))


        var null_count = 0
        var validity_opt: Optional[Bitmap[HeapRegion]] = None
        if any_nulls:
            null_count = out_validity.null_count()
            validity_opt = out_validity^
        # If no nulls, drop validity entirely to match non-nullable convention.

        out_col = Column[HeapRegion](
            arrow_type=ArrowType.STRING,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity_opt^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
    except e:
        # Step 2 already destroyed all cond-mask slots on its normal path,
        # but the heap allocation itself is still live — free it here since
        # on raise the caller's `cond_masks_ptr.free` line is skipped by
        # exception propagation (matches `_run_case_overlay`'s contract).
        cond_masks_ptr.free()
        for j in range(num_cases + 1):
            (then_cols_ptr + j).unsafe_deinit_pointee()
        then_cols_ptr.free()
        winner_ptr.free()
        raise e^

    # ----- Cleanup -------------------------------------------------------
    # Cond masks were destroyed inside the Step-2 loop. THEN cols + default
    # (slot num_cases) are destroyed here: we consumed them via random-access
    # pointers, not by moving them out. winner_ptr is a plain UInt8 heap
    # array — free it.
    for j in range(num_cases + 1):
        (then_cols_ptr + j).unsafe_deinit_pointee()
    then_cols_ptr.free()
    winner_ptr.free()
    return out_col^
