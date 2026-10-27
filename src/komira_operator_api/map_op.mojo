# =============================================================================
# MapOp -- Rev 4.2 §4.2.1 MorselOperatorImpl for projection/compute
# =============================================================================
#
# Per an internal doc Rev 4.2 §4.2.1 ("Operator
# trait") and §4.4 ("Map / Project operator"). Evaluates a list of
# projection expressions against each input Morsel's RecordBatch and
# replaces `morsel.batch` with the newly-built RecordBatch.
#
# Phase 1f.1 -- FIRST real MorselOperatorImpl in v0.4
# ---------------------------------------------------
# A-2 (`col("price") * 2.0`) is the first benchmark that exercises an
# operator between source and sink. The old fused path runs the equivalent
# OP_PROJECT in morsel_executor.mojo::_execute_operator via
# `_eval_column_expr`; MapOp reuses that exact helper so the output bytes
# match the legacy path (byte-equal gate in tests/integration/
# test_a2_byte_equal.mojo).
#
# State and concurrency
# ---------------------
# MapOp owns:
#   * `_expr_ids`: List[ExprId] resolving against the shared ExprPool.
#   * `_names`: parallel List[String] giving each output column's name
#     (the user's alias, or the source column's name for pass-through
#     col_refs). `len(_names) == len(_expr_ids)` is the invariant.
#   * `_pool`: `ArcPointer[ExprPool]`. The pool is Arc-owned by the
#     caller (plan compiler / benchmark harness). Each per-worker MapOp
#     holds its own Arc handle; refcount-bump happens once at driver-
#     side construction (not per morsel). Per §4.2.5.1 answer on ExprPool
#     handoff -- the Arc guarantees lifetime across every execute() call.
#
# Per an internal doc §1.1,
# `MorselOperatorImpl` is Movable-only (NOT
# Copyable). The driver constructs a `Slab[MapOp]` of N instances
# (one per worker) and the executor hands each worker a mutable pointer
# to its own slot. Dropping Copyable lets `_pool` drop from raw
# `UnsafePointer` (the last vestige of "every field must be bitwise-
# Copyable") to the safer `ArcPointer[ExprPool]`.
#
# Execute contract
# ----------------
# `execute(mut self, mut morsel) raises -> ExecResult`. For every input
# morsel, MapOp builds a new RecordBatch by evaluating each expression
# against `morsel.batch` and swaps it into `morsel.batch`. Row count is
# unchanged (Map is a 1:1 operator), so `partition_id` and `origin_hint`
# carry through unchanged, preserving the sink's sort key. Always returns
# `NEED_MORE_INPUT` -- Map produces exactly one output per input with no
# buffered state.
# =============================================================================

from std.builtin.swap import swap
from std.memory import ArcPointer, OwnedPointer
from std.time import perf_counter_ns

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_exec_types.exec_result import (
    ExecResult,
    NEED_MORE_INPUT,
)
from komira_plan_expr.expr_id import ExprId
from komira_plan_expr.expr_pool import ExprPool
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_batch_eval.eval_column import _eval_column_expr
from komira_column_kernels.compiler_helpers import (
    field_for_expr,
    materialize_selection_if_present,
    resolve_col_index,
    # The PROJECT-SHARE arm (share-if-eligible, else `copy_column`, with
    # `copy_column`'s metadata normalisations applied). Imported rather than
    # re-derived so the two cannot drift.
    _project_column,
)
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_ALIAS,
    EXPR_STRING_FN,
    STRFN_LENGTH,
    STRFN_STRLEN,
    STRFN_BIT_LENGTH,
    STRFN_ASCII,
    STRFN_UNICODE,
)
from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    new_owned_metrics_set,
)


# =============================================================================
# THE SELECTION-MASK / PROJECTION CONTRACT  ()
# =============================================================================
#
# A `RecordBatch` carrying an unapplied `_selection_mask` STILL HOLDS THE ROWS
# THE PUSHED PREDICATE REJECTED — the parquet scan's SEL_PIPE defer arm
# (`parquet_source._sel_pipe_should_defer`) and `_decode_with_late_mat`'s
# high-selectivity short-circuit both emit that shape deliberately, to skip a
# near-full gather. `compiler_helpers`'s C.1 block states the consumer contract:
# every consumer must EITHER honor the mask natively OR call
# `materialize_selection_if_present`.
#
# ⛔ A PROJECTION THAT EVALUATES ITS EXPRESSIONS OVER THE WHOLE PHYSICAL BATCH
# AND FORWARDS THE MASK DOES NEITHER. That third option is value-equivalent
# ONLY while every projected expression is TOTAL over the physical rows. The
# moment one of them can RAISE on a row's VALUE, a row nobody asked about kills
# the query. MEASURED 2026-09-09 through the SQL door:
#
#     SELECT k, hamming(s, u) FROM T WHERE k IN (1,2,3,5,6,7,8)
#       -> "hamming() — Strings must be of length > 0!"
#
# on a 9-row fixture whose ONLY empty string is row 0 — which that WHERE clause
# EXCLUDES. 7 of 9 rows survive, `surviving/total = 0.78 >= 0.5`, so the scan
# DEFERRED the gather and handed the projection all nine rows plus a mask. The
# same filter over 3 of 9 rows (0.33 < 0.5) GATHERS and answers correctly, which
# is why the bug reads as if it were about the size of the IN-list.
#
# `hamming`/`mismatches` are not the class. Anything with a row-level
# precondition is: `lpad`/`rpad` ("Insufficient padding"), CAST DECIMAL128 ->
# INT32 ("value out of range"), and the `ExpressionExecutor` integer-division
# walkers ("division by zero"), which makes `SELECT a/b FROM t WHERE b <> 0` a
# member.
#
# ⚠ THE POLARITY BELOW IS FAIL-SAFE ON PURPOSE. It enumerates what is PROVABLY
# TOTAL and materializes everything else, so a NEW kernel that can raise costs a
# gather rather than a wrong refusal. An allowlist of RAISING ops would have the
# opposite polarity and would be wrong by omission the day the next one lands.


def expr_is_column_passthrough(imm e: Expr) -> Bool:
    """True iff evaluating `e` cannot observe any row's VALUE.

    A bare column reference (by name or by index), or an alias of one, is a
    column COPY: `_eval_column_expr` moves bytes and never inspects them, so it
    is total over every physical row and cannot raise on a rejected one. Every
    other shape — arithmetic, CASE, a string function, a cast — reads values and
    is therefore NOT safe to evaluate over rows an unapplied selection mask has
    already rejected.

    ⚠ Conservative by construction: an unrecognised tag answers False (NOT a
    passthrough), which costs a gather and never a wrong answer.

    ⚠ A `def`, not an `fn`, because `Expr.alias_child_ref` is a raising `def`
    (the `Optional._alias.value()` unwrap). Both call sites are already
    `raises`; the body itself has no failure path.
    """
    if e.tag == EXPR_COL_REF or e.tag == EXPR_COL_IDX:
        return True
    if e.tag == EXPR_ALIAS:
        var child_tag = e.alias_child_ref().tag
        return child_tag == EXPR_COL_REF or child_tag == EXPR_COL_IDX
    return False


def expr_is_total_over_rows(imm e: Expr) raises -> Bool:
    """True iff evaluating `e` over EVERY physical row — including rows an
    unapplied selection mask has rejected — cannot raise on any row's VALUE.

    This is the precondition, and the only one, for evaluating a projection
    BEFORE compacting it (see `MapOp.execute`): row-wise evaluation commutes
    with a row gather, so the surviving rows' outputs are the same values
    either way, and the rejected rows' outputs are discarded by the gather.
    What the gather-first order protects against is a RAISE on a rejected
    row (the `hamming` incident in the module block above), and a total
    expression cannot raise.

    ⚠ AN ALLOWLIST, SAME POLARITY AS `expr_is_column_passthrough`. Admitted:

      * a column pass-through (or an alias of one);
      * an alias of an admitted expression;
      * `EXPR_STRING_FN` with op `length` / `strlen` / `bit_length` / `ascii`
        / `unicode` over a column pass-through. Their kernels
        (`_utf8_char_count`, `get_length`, `_utf8_first_codepoint`) are
        non-raising functions of the bytes; NULL in is NULL out.

    Everything else answers False and keeps the gather-first order, so a new
    kernel costs a gather, never a wrong refusal. A TYPE error (a string
    function over an INT column) is not a row-VALUE error: it raises for the
    whole column in either order.
    """
    if expr_is_column_passthrough(e):
        return True
    if e.tag == EXPR_ALIAS:
        return expr_is_total_over_rows(e.alias_child_ref())
    if e.tag == EXPR_STRING_FN:
        var op = e.string_fn_op()
        if (
            op == STRFN_LENGTH
            or op == STRFN_STRLEN
            or op == STRFN_BIT_LENGTH
            or op == STRFN_ASCII
            or op == STRFN_UNICODE
        ):
            return expr_is_column_passthrough(e.string_fn_child_ref())
    return False


struct MapOp(MorselOperatorImpl):
    """Projection/compute operator, §4.2.1.

    Fields
    ------
    _expr_ids: ExprIds resolved against `_pool`. Each produces exactly one
        output column.
    _names: Parallel output column names. `len(_names) == len(_expr_ids)`.
    _pool: ArcPointer[ExprPool] - shared-ownership handle. Each per-worker
        MapOp holds its own Arc handle; the pool drops when the last
        MapOp (and any raw-pointer escape held by LoweredSourceHooks) is
        released.
    """

    var _expr_ids: List[ExprId]
    var _names: List[String]
    # ArcPointer[ExprPool]: shared ownership. Replaces the pre
    # raw wildcard-origin UnsafePointer field. Arc lets the driver
    # distribute refcount handles to N per-worker MapOp instances; the
    # pool drops when the last holder releases. No per-morsel cost --
    # refcount bumps occur only at driver-side construction.
    var _pool: ArcPointer[ExprPool]
    # Phase 3.2 (an internal doc §5.5): per-instance MetricsSet.
    # OwnedPointer[MetricsSet] gives MapOp a stable address for the
    # non-Movable MetricsSet while keeping MapOp itself Movable (Mojo's
    # Box<T> shape). Registered metrics:
    #   * Counter "rows_processed" — input rows the operator processed.
    #   * Time "elapsed_compute"   — accumulated nanoseconds spent in
    #                                 execute().
    var _metrics: OwnedPointer[MetricsSet]
    # PROJECT-SHARE: DEFAULT ON. False turns the pass-through shares of the
    # evaluate-then-compact arm back into copies (the differential oracle).
    var _project_share: Bool

    def __init__(
        out self,
        var expr_ids: List[ExprId],
        var names: List[String],
        var pool: ArcPointer[ExprPool],
        project_share: Bool = True,
    ) raises:
        """Construct a MapOp with a list of output projections.

        Args:
            expr_ids: Registered ExprIds (one per output column).
            names: Parallel list of output column names; must have the
                same length as `expr_ids`.
            pool: Arc-shared ownership of the ExprPool. The caller
                passes a refcount handle; no deep copy.
            project_share: DEFAULT ON. Pass-through columns of the
                evaluate-then-compact arm are Arc shares; False copies them,
                which is the differential oracle for the sharing.
        """
        self._project_share = project_share
        self._expr_ids = expr_ids^
        self._names = names^
        self._pool = pool^
        # Phase 3.2: per-instance MetricsSet, allocated via the
        # validated alloc + in-place __init__ + OwnedPointer factory
        # in komira_metrics (MetricsSet is non-Movable; `OwnedPointer[T]
        # (value=...)` requires T: Movable).
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        # Lane G arming counter: batches that took the evaluate-then-compact
        # arm (`compact_after` in `execute`). A value test cannot see the arm
        # (it is value-identical by construction), so this is its witness.
        _ = ms_ptr[].register_counter["total_eval_compacts"]()
        self._metrics = ms_ptr^

    def metrics_snapshot(self) -> MetricsSnapshot:
        """Phase 3.2: reduce the per-instance MetricsSet for EXPLAIN
        ANALYZE consumption. Off the hot path."""
        return self._metrics[].reduce()

    # Default moveinit / del synthesised: Lists are Movable, ArcPointer
    # is Movable (refcount transfer). NOT marked Copyable -- the trait
    # is Movable-only after the cleanup, and the driver
    # constructs N MapOp instances directly into a `Slab[MapOp]`
    # rather than relying on auto-copy.

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        """Evaluate the projection list against morsel.batch and swap in
        the new RecordBatch.

        Returns NEED_MORE_INPUT unconditionally (Map is 1:1, no buffered
        output).

        Phase 3.2: records `rows_processed` and `elapsed_compute` into
        the per-instance MetricsSet. Each MapOp instance is per-worker
        (the executor builds a Slab[MapOp] of num_workers slots), so
        only ONE writer ever touches `worker_id=0` here — disjointness
        trivially holds. EXPLAIN ANALYZE reduces across all per-worker
        MapOp snapshots.
        """
        var _t0 = perf_counter_ns()
        var _rows_in = morsel.num_rows()
        var num_exprs = len(self._expr_ids)
        if num_exprs == 0:
            # Empty projection -- leave the batch as-is. Degenerate but
            # not an error; matches OP_PROJECT legacy behavior.
            self._metrics[].counter["rows_processed"]().inc_in_pipeline(
                Int64(_rows_in), worker_id=0
            )
            self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
                Int64(perf_counter_ns() - _t0), worker_id=0
            )
            return ExecResult(NEED_MORE_INPUT)

        # ⛔ SELECTION-MASK CONTRACT — see the module block above
        # `expr_is_column_passthrough`. If this batch still carries an
        # unapplied mask, the rows the pushed predicate REJECTED are still
        # physically present, and evaluating a value-observing expression over
        # one of them can raise for a row the query excluded. Materialize FIRST
        # in that case; the C.1 mask transfer at the bottom then finds no mask
        # (`materialize_selection_if_present` clears it) and is a no-op.
        #
        # A projection of pure column pass-throughs keeps the zero-copy
        # forward — it cannot observe a value, so the deferred gather (the
        # measured SEL_PIPE / late-mat win) survives the shape that earns it.
        #
        # ⭐ EVALUATE, THEN COMPACT THE NARROW OUTPUT (lane G, L1). When every
        # expression is TOTAL over the physical rows (`expr_is_total_over_rows`)
        # the order is inverted: the projection runs over the whole physical
        # batch and only its OUTPUT is gathered. `length(url)` then reads `url`
        # in place instead of gathering it first — on cbq27 that gather was a
        # full copy of the surviving `url` bytes per batch (C-gather, 6.4% of
        # the cell's CPU) to feed a kernel whose output is 8 bytes a row.
        # The output is compacted rather than forwarded with the mask, so every
        # consumer sees exactly the dense batch it saw before (the aggregate's
        # masked upsert is a different, slower arm).
        #
        # ⚠ THE COST MODEL LEANS ON THE MASK'S PRODUCER. Evaluating over every
        # physical row beats gather-first only when most rows survive: a
        # byte-walking kernel (`length`) over rejected rows is wasted work,
        # while the gather it replaces copies survivors only. Today the only
        # producer of an unapplied mask is the parquet SEL_PIPE arm, and it
        # DEFERS (emits a mask) only for a NON-selective pushed filter
        # (`_sel_pipe_should_defer`, VECTOR-NATIVE INC-5); a selective filter
        # arrives here already gathered, with no mask. A new mask producer
        # that forwards selective masks re-opens this trade-off — correctness
        # is unaffected either way (both orders select the same rows).
        var compact_after = False
        if morsel.batch.has_selection_mask():
            var needs_dense = False
            var all_passthrough = True
            for e in range(num_exprs):
                ref probe = self._pool[].resolve(self._expr_ids[e])
                if expr_is_column_passthrough(probe):
                    continue
                all_passthrough = False
                if not expr_is_total_over_rows(probe):
                    needs_dense = True
                    break
            if not needs_dense and not all_passthrough:
                compact_after = True
            if needs_dense:
                # `swap` + `replace_batch` — the encapsulated batch extraction
                # (`op_chain_adapter._apply_filter`'s idiom). NOT
                # `UnsafePointer(to=morsel.batch).take_pointee()`: that is the
                # banned partial-move-through-a-raw-pointer shape.
                var extracted = RecordBatch()
                swap(morsel.batch, extracted)
                morsel.replace_batch(
                    materialize_selection_if_present(extracted^)
                )
                # The operator now processes the DENSE row count; report that,
                # not the physical count it was handed.
                _rows_in = morsel.num_rows()

        var builder = RecordBatchBuilder()
        var sb = SchemaBuilder()
        # The PROJECT-SHARE switch applies only on the arm that uses it.
        # Switched off (its differential oracle) it turns this arm's
        # pass-through shares back into copies too.
        var share_passthrough = compact_after and self._project_share
        for e in range(num_exprs):
            ref expr = self._pool[].resolve(self._expr_ids[e])
            var col: Column[HeapRegion]
            if compact_after and expr_is_column_passthrough(expr):
                # The gather below builds this column afresh, so the physical
                # column is only READ here: take the PROJECT-SHARE arm (an Arc
                # share wherever it equals `copy_column`) instead of copying
                # every physical row only to gather the survivors out of it.
                col = _project_column(
                    morsel.batch,
                    resolve_col_index(expr, morsel.batch.schema),
                    share_passthrough,
                )
            else:
                col = _eval_column_expr(expr, morsel.batch)
            var field = field_for_expr(expr, morsel.batch.schema)
            # AGG-SCHEMA-METADATA-PROPAGATION-V0.4: mutate
            # the cloned Field's `name` rather than rebuilding via the
            # bare 3-arg ctor, so Phase B/C metadata survives.
            if e < len(self._names) and self._names[e].byte_length() > 0:
                field.name = self._names[e]
            sb.add_field(field^)
            builder.add_column(col^)

        var schema = sb.build()
        var new_batch = builder.build(schema^)

        # C.1 selection-mask propagation. If the source `morsel.batch` is
        # carrying an unapplied filter mask from `_decode_with_late_mat`'s
        # high-selectivity short-circuit, transfer it to `new_batch` so
        # downstream consumers continue to honor it. The mask's
        # `length` equals the source batch's `num_rows`, which equals
        # `new_batch.num_rows()` because projection is 1:1.
        var mask_taken: Optional[BooleanArray] = None
        if morsel.batch.has_selection_mask():
            mask_taken = morsel.batch.take_selection_mask()
        if mask_taken:
            new_batch.set_selection_mask(mask_taken.take())
        if compact_after:
            # The narrow-output gather (see `compact_after` above). Clears the
            # mask, so the consumer sees the same dense batch as before.
            new_batch = materialize_selection_if_present(new_batch^)
            # Report the DENSE row count, as the gather-first arm this one
            # replaces did (`_rows_in = morsel.num_rows()` after its gather).
            _rows_in = new_batch.num_rows()
            self._metrics[].counter["total_eval_compacts"]().inc_in_pipeline(
                Int64(1), worker_id=0
            )

        # S5 (OpChainAdapter review): swap new_batch into
        # morsel.batch via the safe encapsulated `Morsel.replace_batch`
        # (previously an inline UnsafePointer destroy_pointee/init_pointee_move
        # dance). The C.1 selection-mask transfer above already moved any
        # unapplied mask onto new_batch, so replace_batch dropping the old
        # batch's (already-taken) mask is correct.
        morsel.replace_batch(new_batch^)

        # Phase 3.2: record metrics. Hot-path cost: ~5ns
        # (load+store on per_worker[0]) per counter/time.
        self._metrics[].counter["rows_processed"]().inc_in_pipeline(
            Int64(_rows_in), worker_id=0
        )
        self._metrics[].time["elapsed_compute"]().record_ns_in_pipeline(
            Int64(perf_counter_ns() - _t0), worker_id=0
        )
        return ExecResult(NEED_MORE_INPUT)
