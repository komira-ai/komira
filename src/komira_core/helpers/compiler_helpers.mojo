# =============================================================================
# compiler_helpers — shared batch/column utilities for the pipeline compiler
# =============================================================================
#
# Contains: copy_batch, share_batch, copy_table, share_table, copy_column,
# project_batch_by_names,
# empty_batch_like, empty_batch_like_schema, gather_batch,
# gather_batch_by_sort_indices, element_size, int64_to_float64,
# float64_to_int64, broadcast_scalar, resolve_col_index, field_for_expr
#
# These are public API across packages (no underscore prefixes).
# =============================================================================

from std.memory import UnsafePointer, alloc, unsafe_memcpy, unsafe_memset
from std.sys import size_of, simd_width_of, num_physical_cores
from std.sys.intrinsics import prefetch, PrefetchOptions
from std.ffi import external_call
from std.io import FileDescriptor

# -----------------------------------------------------------------------------
# _STDERR — DIAGNOSTICS DO NOT GO ON THE DATA CHANNEL.
# -----------------------------------------------------------------------------
#
# A query binary that streams Arrow IPC writes its answer to **fd 1**, and this
# file can be inside that binary's link closure. A bare `print(...)` here
# therefore lands IN THE ANSWER, not beside it: diagnostic text ahead of the
# stream is read as the 4-byte length prefix (`[BAR` is `5b 42 41 52`,
# little-endian 0x5241425B == 1380008539, so a reader reports "Expected to
# read 1380008539 metadata bytes"). The answer is INTACT; only the channel is
# corrupt, and it reads as a data regression.
#
# ⚠ ROUTED, NOT DELETED. The `ArrowOffsetPromotion` banner below announces a
# change to the DECLARED TYPE of a user-visible column; a promotion that printed
# nowhere would be worse than one on the wrong fd. Only its destination moves.
#
# Not a logging package's stderr sink: that would add a package dependency for
# a two-call diagnostic, and `print(file=...)` needs no FFI declaration of its
# own.
comptime _STDERR: FileDescriptor = FileDescriptor(2)

# The variable-width gather's per-string copy goes through `fast_copy_bytes`,
# NOT stdlib `memcpy`. Reason, from the object code: stdlib `memcpy`
# INLINE-EXPANDS to a 32 B `vmovups` bulk loop followed by a
# **1-byte-per-iteration scalar remainder loop** for `len mod 32`. On 48-64 B
# join keys that remainder is 16-31 bytes on essentially every string, and for
# 17-31 B keys
# the bulk loop is skipped entirely so the WHOLE copy is byte-at-a-time.
# `fast_copy_bytes` routes 32..128 B through straight-line overlapping 32 B
# vector blocks with no loop and no scalar tail. See
# `komira_core/simd/fast_copy.mojo`.
from ..simd.fast_copy import fast_copy_bytes


# The three gather waves dispatch on the engine runtime via the shared-payload
# fork-join driver; the stdlib `parallelize` pool is not reachable from the
# gather.
from ..runtime_traits.fork_join_shared import fork_join_shared
from ..runtime_traits.parallel_dispatch import NoDispatch, ParallelDispatch
from ..runtime_traits.sched_sites import (
    SITE_GATHER_FIXEDWIDTH,
    SITE_GATHER_STR_LEN,
    SITE_GATHER_STR_SCATTER,
)
from ..runtime_traits.shared_chunk_work import SharedChunkWork
from ..cancellation.token import CancellationToken

from ..arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder, Field
from ..arrow.table import Table
from ..arrow.column import Column
from ..arrow.primitive_array import PrimitiveArray
from ..arrow.string_array import StringArray
from ..arrow.decimal_array import Decimal128Array
from ..arrow.arrow_types import (
    ArrowType,
    arrow_fixed_byte_width,
    widen_offset_type,
)
from ..arrow.owned_aligned_buffer import OwnedAlignedBuffer
from ..io.heap_region import HeapRegion
from ..arrow.bitmap import (
    Bitmap,
    copy_bits_aligned_buffer,
    gather_bits_aligned_buffer,
)
from ..arrow.boolean_array import BooleanArray
from ..arrow.offset_overflow import (
    ARROW_INT32_OFFSET_MAX,
    check_int32_offsets,
    should_promote_offsets,
)
from .gather_width_counter import (
    gather_note_narrow_typed,
    gather_note_width_fallback,
)
from ..eval.comparison import filter_to_indices
from ..eval.cast_null import bitmap_and
from ..eval.union_compute import take_union, _take_column_dispatch
# ⚠ A NEW `EXPR_*` / `BIN_*` / `REGEXP_*` tag import appearing here is a
# signal that a walk is being re-inlined into this file — put it in
# `plan/expr_walk.mojo` instead.
from ..plan.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_COL_IDX,
    EXPR_ALIAS,
)
from ..plan.scalar_value import ScalarValue
from ..plan.agg_expr import AggExpr

# ★ THE Expr WALKS LIVE IN ONE PLACE. `collect_expr_cols` and
# `field_for_expr` below are ADAPTERS over these; a second copy of either
# ladder drifts from the first and breaks production. Read
# `komira_core/plan/expr_walk.mojo`'s header before adding any `.tag ==
# EXPR_*` dispatch to THIS file.
from ..plan.expr_walk import (
    ordered_name_sink,
    walk_expr_column_refs,
    walk_expr_field,
    ExecColRefFields,
)


# =============================================================================
# Column reference collection (for projection pushdown through joins)
# =============================================================================


def collect_expr_cols(expr: Expr, mut out: List[String]):
    """Append every column name `expr` references to `out`, in FIRST-SEEN
    ORDER, duplicates kept (dedupe via `dedupe_names`).

    ★ A THREE-LINE ADAPTER OVER `plan.expr_walk.walk_expr_column_refs` — THE
    ONE column-reference walk. Two copies of this walk drift apart and break
    production. This caller needs ORDER where others dedupe — a difference in
    WHERE THE NAMES GO, which is the `ExprNameSink` parameter.

    ⛔ THE ORDER IS LOAD-BEARING. `ParquetMultiConsumerSource.next_morsel` and
    `streaming_late_mat.compute_late_materialization` decode EXACTLY these
    names, in this order, before evaluating the decode-filter. That guarantee
    is now enforced at COMPILE TIME (`OrderedNameSink.KIND ==
    NameSinkKind.ORDERED`) rather than by this docstring.

    ⛔ DO NOT RE-INLINE THE LADDER HERE. Re-creating a second walk in this
    file is the defect class itself.

    Args:
        expr: The expression tree to walk.
        out: Output list to append column names to.
    """
    var sink = ordered_name_sink(out)
    walk_expr_column_refs(expr, sink)


def collect_agg_expr_cols(agg: AggExpr, mut out: List[String]):
    """Collect column refs from an AggExpr into `out`.

    Walks every populated child slot. For unary aggs only slot 0 is
    populated (sum/count/mean/stddev_samp); for bivariate aggs (corr,
    covar) both slot 0 and slot 1 carry column refs and both must be
    surfaced so the parquet projection includes them.
    """
    if agg.child:
        collect_expr_cols(agg.child.value(), out)
    if agg.child1:
        collect_expr_cols(agg.child1.value(), out)
    if agg.child2:
        collect_expr_cols(agg.child2.value(), out)
    if agg.child3:
        collect_expr_cols(agg.child3.value(), out)


def dedupe_names(var names: List[String]) -> List[String]:
    """Remove duplicates from a list of strings, preserving first-seen order."""
    var result = List[String]()
    for i in range(len(names)):
        var found = False
        for j in range(len(result)):
            if result[j] == names[i]:
                found = True
                break
        if not found:
            result.append(names[i])
    return result^


def has_right_suffix(name: String) -> Bool:
    """True if `name` ends with '_right'."""
    var n = name.byte_length()
    if n <= 6:
        return False
    var ptr = name.unsafe_ptr()
    return (
        ptr[n - 6] == UInt8(ord("_"))
        and ptr[n - 5] == UInt8(ord("r"))
        and ptr[n - 4] == UInt8(ord("i"))
        and ptr[n - 3] == UInt8(ord("g"))
        and ptr[n - 2] == UInt8(ord("h"))
        and ptr[n - 1] == UInt8(ord("t"))
    )


def strip_right_suffix(name: String) -> String:
    """Strip trailing '_right' from `name` if present.

    Used by the join compiler and late-materialization assembly to
    translate post-join collision-suffixed column names back to their
    pre-join (right-side) names. When `name` does not end in '_right',
    returns it unchanged.
    """
    if not has_right_suffix(name):
        return name
    var n = name.byte_length()
    # Build a new String by copying the first (n-6) bytes.
    var result = String("")
    var ptr = name.unsafe_ptr()
    for i in range(n - 6):
        result += chr(Int(ptr[i]))
    return result^


# =============================================================================
# Column index resolution
# =============================================================================


def resolve_col_index(expr: Expr, schema: Schema) raises -> Int:
    """Resolve a column expression to a column index in the schema.

    Handles ColRef (by name), ColIdx (by index), and Alias (recurse into child).
    """
    if expr.tag == EXPR_COL_REF:
        var name = expr.col_ref_name()
        return schema.column_index(name)
    elif expr.tag == EXPR_COL_IDX:
        return expr.col_idx_index()
    elif expr.tag == EXPR_ALIAS:
        return resolve_col_index(expr.alias_child_ref(), schema)
    else:
        raise Error("PipelineCompiler: cannot resolve column index from expression tag: " + String(Int(expr.tag)))


def expr_resolves_to_column(expr: Expr) -> Bool:
    """True iff `resolve_col_index(expr, ...)` would resolve `expr` to a
    single column index WITHOUT raising.

    This is the structural precondition of `resolve_col_index`: the expr is a
    bare ColRef / ColIdx, or an Alias that (transitively) wraps one. A compound
    expression (BinaryOp such as `a * b`, Cast, UnaryOp, …) does NOT resolve to
    a column and must instead be materialized via `_eval_column_expr` before it
    can participate in a comparison. Callers use this as the branch predicate
    between the bare-column fast path and the compute-then-compare path (the
    same generalization the RHS of a comparison has, applied to the LHS).
    """
    if expr.tag == EXPR_COL_REF or expr.tag == EXPR_COL_IDX:
        return True
    elif expr.tag == EXPR_ALIAS:
        return expr_resolves_to_column(expr.alias_child_ref())
    else:
        return False


# =============================================================================
# Field inference for projection
# =============================================================================


def field_for_expr(expr: Expr, schema: Schema) raises -> Field:
    """Infer the output Field for `expr` given a parent schema, RAISING if a
    referenced column is not in `schema`.

    ★ A ONE-LINE ADAPTER OVER `plan.expr_walk.walk_expr_field` — THE ONE
    output-field inference — selecting the EXECUTION-TIME column-reference
    policy. A second copy of that inference drifts from the plan-side one
    (fewer arms), and every expression the copy misses exports as Arrow type
    `null`.

    ⭐ THE RAISE IS THE ONE THING THAT STILL DISTINGUISHES THIS ENTRY POINT
    FROM THE PLAN-SIDE ONE, and it is COMPILER-ENFORCED rather than merely
    documented: `logical_plan._infer_expr_field` is a NON-RAISING `def`
    because `LogicalPlan.project` / `.aggregate` are non-raising constructors
    that synthesize `output_schema` through it. So the shared walk cannot
    raise, and this adapter converts its `missing` report into the Error an
    operator needs — an operator running over a real batch cannot continue
    past a missing column and has no later validator to produce a better
    message. `ExecColRefFields` additionally selects the FULL metadata clone
    (tz, flags, dict/union, kv-metadata, stored dtype).

    Comparison BinaryOps are NOT a difference between the two entry points:
    they are inferred identically (see `expr_walk`).

    ⛔ DO NOT RE-INLINE THE LADDER HERE. See `collect_expr_cols`.

    Args:
        expr: The expression to infer an output Field for.
        schema: The batch schema the expression is evaluated against.
    """
    var missing = String("")
    var f = walk_expr_field[ExecColRefFields](expr, schema, missing)
    if missing.byte_length() > 0:
        # ⚠ THE MESSAGE IS `Schema.column_index`'s, VERBATIM. Callers and
        # tests match on this text. The walk is non-raising (it backs the
        # non-raising plan constructors), so the raise lives HERE, with
        # `column_index`'s wording.
        raise Error("Schema.column_index: no field named '" + missing + "'")
    return f^

# =============================================================================
# Batch operations
# =============================================================================


def copy_batch(batch: RecordBatch) raises -> RecordBatch:
    """Create a copy of a RecordBatch (copies all column data)."""
    var num_cols = batch.num_columns()
    var num_rows = batch.num_rows()

    # Fully-empty short-circuit (no schema fields AND no rows): return a
    # bare RecordBatch. `num_cols == 0` alone is sufficient since we only
    # reach this branch when the schema itself is empty.
    if num_cols == 0:
        return RecordBatch()

    # Zero-row, non-empty-schema: rebuild the schema AND produce one empty
    # Column per field. A batch whose `_columns.len()` is 0 reports
    # `num_columns() == 0` to callers (the accessor reads the column slab,
    # not the schema), so the downstream collect sink would surface the
    # zero-row result as "schema lost". `copy_column` handles num_rows=0
    # via the `max(n * elem_size, 1)` buffer pattern used by
    # `PrimitiveArray.allocate` etc.
    if num_rows == 0:
        var sb0 = SchemaBuilder()
        var builder0 = RecordBatchBuilder()
        for c in range(num_cols):
            # Use `Schema.field_at` to clone the full Field — preserves `_tz`, decimal (p,s),
            # `_dict_index_type`, `_union_type_ids`, `_flags`, and per-field
            # kv-metadata.  The bare 3-arg Field ctor would zero-fill all of
            # these (silent fidelity bug for TIMESTAMP-tz, DECIMAL128, and
            # any field carrying Arrow extension metadata).
            sb0.add_field(batch.schema.field_at(c))
            var col0 = copy_column(batch, c)
            builder0.add_column(col0^)
        var schema0 = sb0.build()
        return builder0.build(schema0^)

    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for c in range(num_cols):
        # `Schema.field_at`: see note in zero-row arm.
        sb.add_field(batch.schema.field_at(c))
        var col = copy_column(batch, c)
        builder.add_column(col^)

    var schema = sb.build()
    return builder.build(schema^)


def share_batch(batch: RecordBatch) raises -> RecordBatch:
    """Arc-SHARE a RecordBatch: return a new RecordBatch whose columns ALIAS
    `batch`'s buffers via Arc refcount bumps — NO byte copies. The zero-copy
    dual of `copy_batch`.

    `share_batch(b)` reads every logical cell IDENTICALLY to `copy_batch(b)`
    (the byte-equivalence oracle asserts this across the dtype zoo), but pays
    an Arc refcount bump per column-buffer instead of a full memcpy.

    WHERE IT PAYS: sharing removes a memcpy of the whole batch. Where that
    memcpy is overlapped by a concurrent latency-bound probe (a cached-scan
    resolution site), removing it does not move the wall; where it runs on the
    driver thread with nothing to overlap it (a resident in-memory leaf), it
    does. The scan-dedup cache (`ScanDedupCache.lookup_copy`) and the
    in-memory leaf resolution both share: under an Arc, cache eviction means
    "drop one reference", not "free the bytes", so sole ownership is not
    load-bearing. ⇒ THE PER-HIT PRICE OF THAT CACHE IS O(ncols) REFCOUNT
    BUMPS, NOT A MEMCPY OF THE CACHED RELATION.

    SOUNDNESS: see `Column.share` — Arrow buffers are immutable on every
    downstream consumer (split / join / agg / filter / project all READ and
    emit NEW batches), and the mmap keepalive is cloned, so aliasing the
    cache/source buffers never exposes a write-through-alias hazard.

    Structure mirrors `copy_batch`: the fully-empty (no schema fields)
    short-circuit returns a bare RecordBatch; otherwise every column is
    shared and the schema is rebuilt via `Schema.field_at` (preserving tz /
    decimal (p,s) / dict index type / per-field kv-metadata). `Column.share`
    handles the zero-row case (it shares whatever buffers the source carries),
    so no separate zero-row arm is required — a zero-row non-empty-schema
    batch still emits one shared column per field, keeping
    `num_columns() == num_cols` (the concern the `copy_batch` zero-row arm
    guards).
    """
    var num_cols = batch.num_columns()

    # Fully-empty short-circuit (no schema fields): bare RecordBatch — mirror
    # of `copy_batch`.
    if num_cols == 0:
        return RecordBatch()

    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for c in range(num_cols):
        # `Schema.field_at` clones the full Field
        # (tz, decimal p/s, dict index type, kv-metadata) — same as copy_batch.
        sb.add_field(batch.schema.field_at(c))
        var col = batch.column_at(c).share()
        builder.add_column(col^)

    var schema = sb.build()
    return builder.build(schema^)


# =============================================================================
# Table operations -- the CHUNK-SEQUENCE duals of `copy_batch` / `share_batch`
# =============================================================================
#
# ⭐ WHY THESE ARE FREE FUNCTIONS AND NOT `Table.copy()`, AND IT IS THE SAME
# REASON `RecordBatch` HAS NO `.copy()`. `Table` is `Movable` and deliberately
# NOT `Copyable`: "duplicate this table" has TWO answers with different costs
# and different ALIASING, and the type system refuses to pick one for you. A
# derived `Copyable` would silently pick deep-copy at every implicit copy the
# compiler inserts; an Arc-sharing one would silently pick aliasing. So the
# decision stays at the CALL SITE, spelled, exactly as `copy_batch` vs
# `share_batch` already spell it one level down.
#
# ⛔ OFFERING ONLY ONE OF THEM WOULD RE-HIDE THAT DECISION. A caller handed
# only `copy_table` reads it as "the way to duplicate a Table" rather than as
# "the deep-copy one", which is how a tee ends up paying N memcpys nobody chose
# -- or, worse, how the opposite edit ships: someone reaches for the cheap
# primitive at a site whose consumers expected independent ownership.
#
# NEITHER CONCATENATES. Both preserve the chunk COUNT and the chunk
# BOUNDARIES, which is what makes them usable at a chunked-result site: the
# engine never concatenates to satisfy a type signature.
# =============================================================================


def copy_table(table: Table) raises -> Table:
    """DEEP-COPY a `Table`: every chunk through `copy_batch`, so the result
    shares NO buffer with `table`. The chunk-sequence dual of `copy_batch`.

    INDEPENDENT OWNERSHIP. The returned table's buffers are fresh allocations;
    destroying either table leaves the other intact, and nothing either does
    is visible through the other. This is the primitive for a consumer that
    expects to own what it was handed -- e.g. a tee whose early consumers get
    a clone while the last one move-takes the original.

    CHUNK-PRESERVING. `num_chunks()`, the per-chunk row counts and the chunk
    ORDER all survive; there is no concat. `n == 0` returns a 0-chunk table
    carrying the same schema -- the empty-result shape, which is exactly the
    case a `RecordBatch`-typed cache field could not express.

    ⚠ IT RE-VALIDATES THROUGH `Table.from_chunks`, SO IT CAN RAISE WHERE THE
    INPUT DID NOT. `Table.from_batch` performs no cross-chunk check (it has one
    chunk by construction), so a table built that way over a batch whose
    PHYSICAL column count disagrees with its own schema is admitted at
    construction and refused here. That direction is deliberate: the refusal
    names the disagreement at the copy, where a stride-by-the-wrong-width read
    downstream would not.

    Args:
        table: The table to deep-copy. Borrowed; unchanged by this call.

    Returns:
        A `Table` with the same schema, chunking and values, sharing no buffer.
    """
    var n = table.num_chunks()
    var out = List[RecordBatch](capacity=n)
    for i in range(n):
        out.append(copy_batch(table.chunks()[i]))
    return Table.from_chunks(out^, table.schema().copy())


def share_table(table: Table) raises -> Table:
    """Arc-SHARE a `Table`: every chunk through `share_batch`, so the result
    ALIASES `table`'s column buffers via refcount bumps -- NO byte copies. The
    chunk-sequence dual of `share_batch`, and the zero-copy dual of
    `copy_table`.

    `share_table(t)` reads every logical cell IDENTICALLY to `copy_table(t)`
    and carries the same schema and the same chunk boundaries; it pays an Arc
    refcount bump per column-buffer instead of a memcpy per column.

    SOUNDNESS -- and it is a PRECONDITION ON THE CONSUMERS, not a property of
    this function. See `share_batch` and `Column.share`: aliasing is safe
    because Arrow buffers are immutable on every downstream consumer in this
    engine (split / join / agg / filter / project all READ and emit NEW
    batches) and the mmap keepalive is cloned, so no write-through-alias
    hazard exists. ⛔ A consumer that MUTATES a column in place -- the
    `set_valid` / `set_null` / `_unsafe_data_ptr` / `view_mut` family -- writes
    THROUGH to every other holder. Hand such a consumer `copy_table`.

    ⚠ NOT A DROP-IN FOR `copy_table` AT A TEE. The two differ in exactly one
    observable way and it is ownership, not speed: a tee that hands N consumers
    a shared table when they expect independent ownership is a CORRECTNESS
    defect, not a perf one. Switching a site from copy to share is an
    aliasing-contract change and wants the site's own argument (and, if it is
    on a hot path, its own measurement -- `share_batch`'s docstring notes that
    an eliminated memcpy which is overlapped by other work does not move the
    wall at all).

    Args:
        table: The table to share. Borrowed; unchanged by this call.

    Returns:
        A `Table` with the same schema, chunking and values, ALIASING
        `table`'s buffers.
    """
    var n = table.num_chunks()
    var out = List[RecordBatch](capacity=n)
    for i in range(n):
        out.append(share_batch(table.chunks()[i]))
    return Table.from_chunks(out^, table.schema().copy())


def column_buffer_bytes(batch: RecordBatch, col_idx: Int) raises -> Int:
    """Backing BUFFER bytes of ONE column — the quantity `copy_column` moves
    and `Column.share()` does not.

    Read-only metadata arithmetic (buffer LENGTHS, not contents), so it is
    O(1), not O(bytes). Mirrors `ExternalSorter._estimate_batch_bytes`'s
    accounting (`_data` + `_offsets` + validity + dict values). It exists so
    the registry-inline counter can report a byte figure COMPUTED FROM THE
    BATCH rather than a self-reported constant."""
    ref col = batch.column_at(col_idx)
    var total = col._data.len()
    if col._offsets:
        total += col._offsets.value().len()
    if col._validity:
        # Bitmap stores `length` in BITS; storage is (length + 7) >> 3.
        total += (col._validity.value().length + 7) >> 3
    if col._dict_data:
        total += col._dict_data.value().len()
    return total


def batch_buffer_bytes(batch: RecordBatch) raises -> Int:
    """Sum of `column_buffer_bytes` over `batch`'s columns."""
    var total = 0
    var nc = batch.num_columns()
    for c in range(nc):
        total += column_buffer_bytes(batch, c)
    return total


def share_batch_like_copy(batch: RecordBatch) raises -> RecordBatch:
    """`copy_batch`'s STRUCTURAL TWIN with every share-ELIGIBLE column
    Arc-shared instead of memcpy'd. Ineligible columns are handed to
    `copy_column` verbatim, so the result is interchangeable with
    `copy_batch(batch)` on every consumer, column by column.

    WHY NOT `share_batch`. `share_batch` calls `Column.share()` RAW, and
    `copy_column` is not a pure copy — it also NORMALISES:

      * it DROPS an all-valid validity bitmap (`_null_count == 0`), which is
        what makes a downstream `if col._validity:` guard short-circuit;
      * it BACK-FILLS DECIMAL (p, s) from the batch schema when the column
        carries none;
      * it REBASES a row-slice to `_offset == 0` and trims leading data bytes.

    A raw share preserves all three verbatim, so swapping `copy_batch` for
    `share_batch` at a site whose consumers branch on `_validity` is NOT a
    structural no-op. `_project_column` (the PROJECT-SHARE arm) resolves
    exactly this: it applies the first two
    normalisations to the shared column and defers to `copy_column` whenever
    `project_column_share_eligible` fails — which is where the third lives,
    the `_offset == 0` gate that matters most, because plain STRING / BINARY
    accessors IGNORE `_offset` and a shared row-sliced STRING column would
    read the WRONG CELLS silently. This function is that per-column decision
    lifted to the batch, with `copy_batch`'s schema construction
    (`Schema.field_at`, preserving tz / decimal (p,s) / dict index type /
    per-field kv-metadata) unchanged.

    The eligibility predicate — NOT an argument about who calls this — is what
    makes the swap sound."""
    var num_cols = batch.num_columns()

    # Fully-empty short-circuit (no schema fields AND therefore no columns):
    # bare RecordBatch — mirror of `copy_batch` / `share_batch`.
    if num_cols == 0:
        return RecordBatch()

    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for c in range(num_cols):
        sb.add_field(batch.schema.field_at(c))
        # `_project_column(.., share_on=True)` = share-if-eligible with
        # `copy_column`'s two metadata normalisations applied, else
        # `copy_column` itself. The zero-row case falls out of the predicate:
        # `RecordBatch.empty_from_schema`'s `_zero_length_column` carries an
        # offsets view shorter than one entry, which the predicate rejects, so
        # such a column is deep-copied.
        var col = _project_column(batch, c, True)
        builder.add_column(col^)

    var schema = sb.build()
    return builder.build(schema^)


def copy_column(batch: RecordBatch, col_idx: Int) raises -> Column[HeapRegion]:
    """Copy a single column from a RecordBatch.

    Handles both fixed-width types (int, float, bool) and variable-length
    types (string) by copying the offsets buffer when present.
    """
    ref col = batch.column_at(col_idx)
    var num_rows = batch.num_rows()
    var at = col.arrow_type

    # Copy validity bitmap (common to all types).
    #
    # Three cases, ranked by frequency on the production hot paths (the JOIN
    # BUILD column copy is a large share of driver-thread time):
    #   1. Source has NO validity bitmap -> destination has none either.
    #   2. Source has validity bitmap but `null_count == 0` -> Arrow
    #      allows omitting validity in this case (null_count==0 with a
    #      bitmap present is legal); we drop it on the destination so the downstream
    #      `if col._validity:` guard short-circuits, and we eliminate
    #      the per-row bitmap rebuild entirely. This is the common case
    #      for the JOIN BUILD ingest path.
    #   3. Source has validity bitmap with real nulls -> bulk-copy the
    #      bit slice via `Bitmap.copy_slice_from`, which uses memcpy
    #      on the byte-aligned fast path (col._offset % 8 == 0) and a
    #      scalar bit-shift fallback otherwise. Neither path walks
    #      `for r in range(num_rows): bm.set/clear(r)` per row.
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if col._validity:
        if col._null_count == 0:
            # Path 2: drop the all-1s validity. Destination has no
            # bitmap, null_count stays 0. No per-row loop, no allocation.
            pass
        else:
            # Path 3: bulk-copy the bit slice (memcpy on byte-aligned
            # fast path, scalar shift on misaligned). For the common
            # non-sliced case (col._offset == 0 AND num_rows ==
            # col._length, which is what `materialize_with_pool` and
            # the JOIN BUILD ingest produce), the source's stored
            # `_null_count` is authoritative -- preserve it. For
            # genuine sub-slices, recount via the bitmap's own
            # SIMD popcount (`Bitmap.null_count()`), which is one
            # `cnt.16b + addv` pass over `num_bits/8` bytes -- still
            # vastly faster than a per-row loop.
            var bm = Bitmap.copy_slice_from(
                col._validity.value(), col._offset, num_rows
            )
            if col._offset == 0 and num_rows == col._length:
                null_count = col._null_count
            else:
                null_count = bm.null_count()
            validity = bm^

    # Nested types (LIST / STRUCT / MAP /
    # UNION_*) own children stored in `_children` (Slab[Column]) plus
    # auxiliary per-shape slots (field_names, keys_sorted, type_ids).
    # The fixed-width / variable-length branches below don't preserve
    # any of that.  The lossless path is `Column.deep_copy()`, which
    # recursively clones every buffer + child Column + auxiliary slot.
    # For the non-sliced case (offset == 0 and num_rows == col.length),
    # this is the right answer.
    if (
        at == ArrowType.LIST
        or at == ArrowType.STRUCT
        or at == ArrowType.MAP
        or at == ArrowType.UNION_SPARSE
        or at == ArrowType.UNION_DENSE
    ):
        if col._offset != 0 or num_rows != col._length:
            raise Error(
                "_copy_column: sliced nested/union column (arrow_type="
                + String(at)
                + ", offset=" + String(col._offset)
                + ", num_rows=" + String(num_rows)
                + ", col_len=" + String(col._length)
                + ") — only a full-slice copy is supported"
            )
        return col.deep_copy()

    if at == ArrowType.DICTIONARY and col.is_numeric_dict():
        # A NUMERIC dict has `_offsets == None` — the string-
        # dict copy below would None-unwrap `_offsets`. `deep_copy()` clones a
        # numeric dict losslessly (codes + flat numeric values + value dtype).
        # The non-sliced case is the only one this helper supports for dicts.
        if col._offset != 0 or num_rows != col._length:
            raise Error(
                "_copy_column: sliced NUMERIC dictionary column copy is not"
                " supported (offset=" + String(col._offset)
                + ", num_rows=" + String(num_rows)
                + ", col_len=" + String(col._length) + ")"
            )
        return col.deep_copy()

    if at == ArrowType.DICTIONARY:
        # STRING dict only (numeric dict handled above).
        # Dictionary column: copy indices + shared dictionary (view-based
        # copy_from_view).
        comptime int32_size = size_of[Int32]()
        var idx_bytes = num_rows * int32_size
        var idx_buf = OwnedAlignedBuffer(max(idx_bytes, 1))
        var src_offset = col._offset * int32_size
        if idx_bytes > 0:
            idx_buf.copy_from_view(
                col._data.view_range_ro(src_offset, idx_bytes)
            )
        idx_buf.set_length(Int64(idx_bytes))


        # Copy dictionary offsets
        var dict_offsets_bytes = (col._dict_size + 1) * int32_size
        var dict_offsets_buf = OwnedAlignedBuffer(dict_offsets_bytes)
        dict_offsets_buf.copy_from_view(
            col._offsets.value().view_range_ro(0, dict_offsets_bytes)
        )
        dict_offsets_buf.set_length(Int64(dict_offsets_bytes))


        # Copy dictionary string data
        var dict_data_len = col._dict_data.value().len()
        var dict_data_buf = OwnedAlignedBuffer(max(dict_data_len, 1))
        if dict_data_len > 0:
            dict_data_buf.copy_from_view(
                col._dict_data.value().view_range_ro(0, dict_data_len)
            )
        dict_data_buf.set_length(Int64(dict_data_len))


        var new_col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=idx_buf^,
            offsets=dict_offsets_buf^,
            validity=validity^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
        new_col._set_dict_data_from_oab(dict_data_buf^)
        new_col._dict_size = col._dict_size
        return new_col^
    elif at == ArrowType.STRING or at == ArrowType.BINARY:
        # Variable-length string / binary: copy offsets + data buffers.
        # STRING and BINARY share the identical (offsets, bytes, validity)
        # physical layout — only the type tag differs. Both flow through
        # this branch so `copy_batch` propagates BINARY columns correctly
        # through the join pipeline. Typed offset accessors + view copy.
        if not col._offsets:
            raise Error(
                "_copy_column: variable-length column missing offsets buffer"
                " (arrow_type=" + String(at) + ")"
            )
        comptime int32_size = size_of[Int32]()
        var src_offsets_view = col._offsets.value().view_ro()

        # Compute data range for this slice
        var data_start = Int(
            src_offsets_view.get_typed[Int32](col._offset)
        )
        var data_end = Int(
            src_offsets_view.get_typed[Int32](col._offset + num_rows)
        )
        var data_len = data_end - data_start

        # Copy and rebase offsets (subtract data_start so new offsets start at 0)
        # SIMD-stage the unit-stride Int32 subtract: Mojo does NOT autovec a
        # scalar `for r: set_typed(r, Int32(get_typed(off+r) - data_start))`
        # loop, and over a wide string table that per-row loop dominates
        # `copy_column`. Same pattern as `arrow/copy_column_ref.mojo`.
        var offsets_buf = OwnedAlignedBuffer((num_rows + 1) * int32_size)
        var base_i32 = Int32(data_start)
        comptime W32 = simd_width_of[DType.int32]()
        var n_off = num_rows + 1
        var src_byte_base = col._offset * int32_size
        var simd_end_32 = (n_off // W32) * W32
        var base_vec_32 = SIMD[DType.int32, W32](base_i32)
        var i32 = 0
        while i32 < simd_end_32:
            var v = src_offsets_view.load_simd[DType.int32, W32](
                src_byte_base + i32 * int32_size
            )
            offsets_buf.store_simd[DType.int32, W32](
                i32 * int32_size, v - base_vec_32
            )
            i32 += W32
        # Scalar tail (< W32 elements).
        while i32 < n_off:
            offsets_buf.set_typed[Int32](
                i32,
                src_offsets_view.get_typed[Int32](col._offset + i32) - base_i32,
            )
            i32 += 1
        offsets_buf.set_length(Int64((num_rows + 1) * int32_size))


        # Copy data bytes
        var data_buf = OwnedAlignedBuffer(max(data_len, 1))
        if data_len > 0:
            data_buf.copy_from_view(
                col._data.view_range_ro(data_start, data_len)
            )
        data_buf.set_length(Int64(data_len))


        return Column[HeapRegion](
            arrow_type=at,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
    elif at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        # LARGE_STRING / LARGE_BINARY are variable-length with Int64
        # offsets and must not fall into the fixed-width branch (which would
        # build a column with NO offsets). Mirrors the STRING/BINARY branch
        # above but with Int64 offsets.
        if not col._offsets:
            raise Error(
                "_copy_column: variable-length column missing offsets buffer"
                " (arrow_type=" + String(at) + ")"
            )
        comptime int64_size = size_of[Int64]()
        var src_offsets_view = col._offsets.value().view_ro()

        var data_start = Int(
            src_offsets_view.get_typed[Int64](col._offset)
        )
        var data_end = Int(
            src_offsets_view.get_typed[Int64](col._offset + num_rows)
        )
        var data_len = data_end - data_start

        # SIMD-stage the Int64 offset rebase loop (mirror of the Int32 STRING/BINARY
        # branch above + canonical pattern in copy_column_ref.mojo).
        var offsets_buf = OwnedAlignedBuffer((num_rows + 1) * int64_size)
        var base_i64 = Int64(data_start)
        comptime W64 = simd_width_of[DType.int64]()
        var n_off = num_rows + 1
        var src_byte_base = col._offset * int64_size
        var simd_end_64 = (n_off // W64) * W64
        var base_vec_64 = SIMD[DType.int64, W64](base_i64)
        var i64 = 0
        while i64 < simd_end_64:
            var v = src_offsets_view.load_simd[DType.int64, W64](
                src_byte_base + i64 * int64_size
            )
            offsets_buf.store_simd[DType.int64, W64](
                i64 * int64_size, v - base_vec_64
            )
            i64 += W64
        # Scalar tail.
        while i64 < n_off:
            offsets_buf.set_typed[Int64](
                i64,
                src_offsets_view.get_typed[Int64](col._offset + i64) - base_i64,
            )
            i64 += 1
        offsets_buf.set_length(Int64((num_rows + 1) * int64_size))


        var data_buf = OwnedAlignedBuffer(max(data_len, 1))
        if data_len > 0:
            data_buf.copy_from_view(
                col._data.view_range_ro(data_start, data_len)
            )
        data_buf.set_length(Int64(data_len))


        return Column[HeapRegion](
            arrow_type=at,
            data=data_buf^,
            offsets=offsets_buf^,
            validity=validity^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
    elif at == ArrowType.BOOL:
        # BOOL IS BIT-PACKED and must not take the `else:` fixed-width slab
        # copy below: at a byte width of 8 that copy would read `num_rows * 8`
        # bytes out of a buffer holding `(num_rows + 7) >> 3`, and on a SLICED
        # boolean column `col._offset * 8` is a byte offset computed from a
        # BIT index, ignoring the sub-byte position -- the wrong rows,
        # silently.
        #
        # `copy_bits_aligned_buffer` is the primitive that gets this right: a
        # memcpy-backed bulk copy when both bit offsets are byte-aligned, a
        # per-bit walk otherwise. `arrow/copy_column_ref.mojo`'s BOOL arm and
        # `Bitmap.copy_bits_into` use the same primitive.
        var bm_bytes = (num_rows + 7) >> 3
        var data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
        data_buf.zero()
        copy_bits_aligned_buffer(
            data_buf, 0, col._data, col._offset, num_rows
        )
        data_buf.set_length(Int64(bm_bytes))
        return Column[HeapRegion](
            arrow_type=ArrowType.BOOL,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
    else:
        # Fixed-width: copy elem_size bytes per row (view-based copy).
        var elem_size = element_size(at)
        var byte_len = num_rows * elem_size

        var data_buf = OwnedAlignedBuffer(max(byte_len, 1))
        var src_offset = col._offset * elem_size
        if byte_len > 0:
            data_buf.copy_from_view(
                col._data.view_range_ro(src_offset, byte_len)
            )
        data_buf.set_length(Int64(byte_len))


        var new_col = Column[HeapRegion](
            arrow_type=at,
            data=data_buf^,
            offsets=None,
            validity=validity^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
        # DECIMAL128-CORRECTNESS: preserve precision/scale metadata.  Prefer
        # the column's own (p,s); fall back to the batch schema if the
        # column wasn't built via Column.from_decimal128 (e.g. a column
        # decoded by a path that doesn't yet set it).
        # Decimal256 carries the
        # same (p, s) metadata and must be propagated identically.  Without
        # this arm a copy_column on a Decimal256 column would silently zero
        # the precision/scale, breaking any downstream as_decimal256() call.
        if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
            if col._decimal_p > 0:
                new_col._decimal_p = col._decimal_p
                new_col._decimal_s = col._decimal_s
            else:
                new_col._decimal_p = batch.schema.field_decimal_precision(col_idx)
                new_col._decimal_s = batch.schema.field_decimal_scale(col_idx)
        return new_col^


def project_batch_by_names(batch: RecordBatch, names: List[String]) raises -> RecordBatch:
    """Project a RecordBatch to include only the named columns.

    PROJECT-SHARE: the carried columns are Arc-SHARED, not memcpy'd, wherever
    `project_column_share_eligible` proves that equivalent — the SAME
    predicate and the SAME `_project_column` arm that
    `project_batch_by_src_out_pairs` uses. This function is that one's by-name
    sibling (a select-and-narrow where `project_batch_by_src_out_pairs` is a
    select-and-rename).

    WHY IT MATTERS HERE: a resident in-memory leaf batch is projected on the
    DRIVER thread with the worker pool idle, and such projections are very
    often byte-for-byte IDENTITY (the exact column set, in the exact order,
    out of a batch that is destroyed two statements later). Sharing moves
    zero bytes.
    """
    return project_batch_by_names_arm(batch, names, True)


# =============================================================================
# PROJECT-SHARE — a pure-col-ref projection does not need to copy bytes
# =============================================================================
#
# WHY. `project_batch_by_src_out_pairs` is the SELECT-and-RENAME primitive:
# it carries columns through UNCHANGED and only re-labels them in the schema.
# Calling `copy_column` per column would allocate a fresh `OwnedAlignedBuffer`
# and memcpy every buffer -- for a join output with a multi-GB string column
# and one rename, gigabytes of single-threaded memcpy on the driver plus the
# kernel page-zeroing of the copy's own first touch, with all workers idle.
#
# `Column.share()` (arrow/column.mojo) is the zero-copy dual of `deep_copy` —
# Arc refcount bumps, no bytes moved — and its byte-equivalence oracle asserts
# it reads every logical cell identically. `share_batch` already ships on the
# join probe/build feed, so the "Arrow buffers are immutable on every
# consumer" premise this rests on is already load-bearing.
#
# WHY AN ELIGIBILITY PREDICATE AND NOT AN UNCONDITIONAL SWAP. `copy_column`
# is not a pure copy:
# it also NORMALISES. It rebases a row-slice to `_offset == 0`, it drops an
# all-valid validity bitmap, and it back-fills DECIMAL (p, s) from the batch
# schema. `share()` preserves `_offset` verbatim — and plain STRING / BINARY
# accessors IGNORE `_offset` (see `Column.supports_zero_copy_slice`), so
# sharing a row-sliced STRING column would read the WRONG CELLS. Callers of
# `project_batch_by_src_out_pairs` can hand it batches this module does not
# control, so the eligibility predicate below is what makes the swap sound
# rather than a claim about who calls it.


def project_column_share_eligible(batch: RecordBatch, col_idx: Int) raises -> Bool:
    """True iff `batch.column_at(col_idx).share()` is provably interchangeable
    with `copy_column(batch, col_idx)` (after the two metadata normalisations
    `_project_column` applies).

    THE THREE GATES, each closing a way `copy_column` does more than copy:

    1. `_offset == 0`. `copy_column` rebases a row-slice to offset 0;
       `share()` preserves `_offset`. For plain STRING / BINARY the accessors
       IGNORE `_offset` entirely (`Column.supports_zero_copy_slice`'s note), so
       a shared sliced STRING column would read from row 0 — a SILENT WRONG
       ANSWER, not a crash. This gate is the one that matters.
    2. `_length == batch.num_rows()`. `copy_column` emits exactly
       `batch.num_rows()` rows regardless of the column's own length, i.e. it
       TRUNCATES an over-long column; `share()` keeps `_length`.
    3. For variable-width layouts, `offsets[0] == 0`. `copy_column` rebases the
       offsets to zero and trims the leading data bytes; `share()` aliases them
       as they stand. Reads agree either way, but a consumer that walks the
       data buffer from byte 0 (a writer, a byte-fold oracle) would see a
       different buffer. Cheap to check, so check it.

    Everything else — fixed-width, BOOL, DECIMAL, STRING dict, numeric dict,
    LIST / STRUCT / MAP / UNION — is eligible under gates 1+2, because under
    those gates `copy_column` is either a straight buffer copy or a
    `deep_copy()`, and `share()` is the exact zero-copy dual of both."""
    ref col = batch.column_at(col_idx)
    if col._offset != 0 or col._length != batch.num_rows():
        return False
    var at = col.arrow_type
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        if not col._offsets:
            # Malformed; let `copy_column` raise its own diagnostic.
            return False
        # The offsets VIEW may be shorter than one entry. `RecordBatch.
        # empty_from_schema`'s `_zero_length_column` allocates a 4-byte offsets buffer and
        # `zero()`s it WITHOUT `set_length`, so `view_ro()` spans [0, 0) and
        # reading offsets[0] there is OUT OF BOUNDS. A PREDICATE MUST NOT BE
        # ABLE TO FAULT: "ineligible" is always an available and always a safe
        # answer, so bounds-check before probing rather than trusting the
        # layout.
        var ov32 = col._offsets.value().view_ro()
        if ov32.len() < size_of[Int32]():
            return False
        return ov32.get_typed[Int32](0) == Int32(0)
    if at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
        if not col._offsets:
            return False
        var ov64 = col._offsets.value().view_ro()
        if ov64.len() < size_of[Int64]():
            return False
        return ov64.get_typed[Int64](0) == Int64(0)
    return True


def _project_column(
    batch: RecordBatch, col_idx: Int, share_on: Bool
) raises -> Column[HeapRegion]:
    """The projected column: an Arc-SHARE when `project_column_share_eligible`,
    else `copy_column`. The share result is normalised to the SAME STRUCTURE
    `copy_column` would have produced, so the swap is invisible to every
    downstream `if col._validity:` / decimal-metadata consumer:

      * validity — `copy_column`'s Path 2 DROPS an all-valid bitmap
        (`_null_count == 0`) so downstream guards short-circuit. Mirrored here.
        NOT applied on the layouts `copy_column` serves via `deep_copy()`
        (nested / union / numeric dict), which keep the bitmap.
      * DECIMAL (p, s) — `copy_column` back-fills from the batch schema when
        the column carries none. Mirrored here."""
    if not share_on or not project_column_share_eligible(batch, col_idx):
        return copy_column(batch, col_idx)

    ref col = batch.column_at(col_idx)
    var at = col.arrow_type
    var deep_copy_arm = (
        at == ArrowType.LIST
        or at == ArrowType.STRUCT
        or at == ArrowType.MAP
        or at == ArrowType.UNION_SPARSE
        or at == ArrowType.UNION_DENSE
        or (at == ArrowType.DICTIONARY and col.is_numeric_dict())
    )
    var out = col.share()
    if not deep_copy_arm:
        if out._validity and out._null_count == 0:
            out._validity = Optional[Bitmap[HeapRegion]](None)
    if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
        if out._decimal_p <= 0:
            out._decimal_p = batch.schema.field_decimal_precision(col_idx)
            out._decimal_s = batch.schema.field_decimal_scale(col_idx)
    return out^


def project_batch_by_src_out_pairs(
    batch: RecordBatch, src_names: List[String], out_names: List[String]
) raises -> RecordBatch:
    """Project a RecordBatch selecting `src_names[i]` and EMITTING it under
    `out_names[i]`. A select-AND-rename (a pure-col-ref project where some outputs
    are RENAMING aliases — `col("src") as "out"`). When `src_names[i] ==
    out_names[i]` for all i, this is identical to `project_batch_by_names`. The
    scalar-broadcast decorrelation aliases its 1-row inner column
    (`col("avg") as "__scalar_subq_0"`); the walker's PROJECT-over-breaker arm uses
    this so the renamed column survives into the residual filter.

    `src_names` and `out_names` MUST be the same length (paired positionally).

    PROJECT-SHARE: the carried columns are Arc-SHARED, not memcpy'd,
    wherever that is provably equivalent — see the block comment above and
    `project_column_share_eligible`. A pure rename moves ZERO bytes.
    """
    return project_batch_by_src_out_pairs_arm(
        batch, src_names, out_names, True
    )


def project_batch_by_src_out_pairs_arm(
    batch: RecordBatch,
    src_names: List[String],
    out_names: List[String],
    share_on: Bool,
) raises -> RecordBatch:
    """`project_batch_by_src_out_pairs` with the PROJECT-SHARE arm selected
    EXPLICITLY.

    This is the one implementation; the public entry point is the thin wrapper
    that always shares. It exists as a separate symbol so the differential
    test can run BOTH arms in ONE process: `share_on=False` is the
    unconditional `copy_column` per column, the share-vs-copy ORACLE."""
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    for i in range(len(src_names)):
        var idx = batch.schema.column_index(src_names[i])
        var src_field = batch.schema.field_at(idx)
        # ★ RENAME THE FIELD; DO NOT REBUILD IT.
        #
        # `sb.add_field(Field(out_names[i], src_field.arrow_type,
        # src_field.nullable))` would reconstruct the output Field from THREE
        # of its FIFTEEN slots and silently drop `decimal_precision`/
        # `decimal_scale`, `_tz`, `_dict_index_type`, `_union_type_ids`,
        # `_flags`, the kv-metadata and the nested-child lists (and re-derive
        # `dtype`, which is `DTYPE_NONE` for every non-numeric type). A DECIMAL
        # carried through a PROJECT-over-SORT would then come back as
        # `decimal128(38, 0)` holding the UNSCALED integer -- `40.00` returned
        # as `4000`, 100x wrong and with NO raise.
        #
        # `field_at` returns a Field BY VALUE, so mutating `name` here renames
        # this copy and carries every other slot. Same shape and same rationale
        # as `field_for_expr`'s EXPR_ALIAS arm in this file. This primitive
        # also serves a PROJECT applied per chunk over a chunked JOIN, which
        # the same fix covers.
        src_field.name = out_names[i]
        sb.add_field(src_field)
        var col = _project_column(batch, idx, share_on)
        builder.add_column(col^)

    var schema = sb.build()
    return builder.build(schema^)


def project_batch_by_names_arm(
    batch: RecordBatch, names: List[String], share_on: Bool
) raises -> RecordBatch:
    """`project_batch_by_names` with the PROJECT-SHARE arm selected EXPLICITLY.

    This is the one implementation; the public entry point is the thin wrapper
    that always shares. It exists as a separate symbol for the same reason
    `project_batch_by_src_out_pairs_arm` does: the differential test must run
    BOTH arms in ONE process. `share_on=False` is the unconditional
    `copy_column` per name.

    NOTE ON DUPLICATE NAMES. `names` may legitimately repeat a source column
    (`SELECT a, a`). Under the copy arm each output owns private bytes; under
    the share arm both outputs Arc-alias ONE buffer. That is sound for the
    same reason the whole primitive is — Arrow buffers are immutable on every
    downstream consumer (see `share_batch`'s SOUNDNESS note) — and it is the
    behaviour `project_batch_by_src_out_pairs` has for
    `col("a"), col("a") as "b"`."""
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    for name in names:
        var idx = batch.schema.column_index(name)
        # `Schema.field_at` preserves the full Field metadata through
        # projection pushdown.
        sb.add_field(batch.schema.field_at(idx))
        var col = _project_column(batch, idx, share_on)
        builder.add_column(col^)

    var schema = sb.build()
    return builder.build(schema^)


def empty_batch_like(batch: RecordBatch) raises -> RecordBatch:
    """Create an empty RecordBatch with the same schema as the input."""
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for i in range(batch.num_columns()):
        # Preserve the full Field metadata when cloning a zero-row batch.
        sb.add_field(batch.schema.field_at(i))
        var at = batch.schema.field_arrow_type(i)
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)


        var offsets = Optional[OwnedAlignedBuffer](None)
        if at == ArrowType.STRING or at == ArrowType.BINARY:
            # Empty string / binary column needs a valid offsets buffer
            # with a single 0 entry. STRING and BINARY share layout.
            comptime int32_size = size_of[Int32]()
            var offsets_buf = OwnedAlignedBuffer(int32_size)
            offsets_buf.set_typed[Int32](0, Int32(0))
            offsets_buf.set_length(Int64(int32_size))

            offsets = offsets_buf^

        var col2 = Column[HeapRegion](
            arrow_type=at,
            data=data_buf^,
            offsets=offsets^,
            validity=Optional[Bitmap[HeapRegion]](None),
            length=0,
            null_count=0,
            offset=0,
        )
        builder.add_column(col2^)

    var schema = sb.build()
    return builder.build(schema^)


def empty_batch_like_schema(schema: Schema) raises -> RecordBatch:
    """Create an empty RecordBatch from a schema (0 rows).

    Creates properly typed 0-length columns for each field in the schema.
    String / binary columns get a valid single-element offsets buffer.
    """
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    for i in range(schema.num_columns()):
        # Preserve the full Field metadata when bootstrapping a zero-row batch
        # from a Schema.
        sb.add_field(schema.field_at(i))
        var at = schema.field_arrow_type(i)
        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)


        var offsets = Optional[OwnedAlignedBuffer](None)
        if at == ArrowType.STRING or at == ArrowType.BINARY:
            comptime int32_size = size_of[Int32]()
            var offsets_buf = OwnedAlignedBuffer(int32_size)
            offsets_buf.set_typed[Int32](0, Int32(0))
            offsets_buf.set_length(Int64(int32_size))

            offsets = offsets_buf^

        var col2 = Column[HeapRegion](
            arrow_type=at,
            data=data_buf^,
            offsets=offsets^,
            validity=Optional[Bitmap[HeapRegion]](None),
            length=0,
            null_count=0,
            offset=0,
        )
        builder.add_column(col2^)

    var out_schema = sb.build()
    return builder.build(out_schema^)


# =============================================================================
# PARALLEL SORT GATHER.
# =============================================================================
#
# The per-column GATHER is a large, otherwise SERIAL stage of every sort. It
# is shared by ALL sorts (int / float / string) and by filter / join probe, so
# a parallel gather is a general win. `gather_batch_dispatch` routes through
# the parallel per-column scatter when the output reaches
# `gather_parallel_min_rows` and a dispatcher was threaded in.
#
# The three waves (STRING pass-1 lengths, STRING pass-2 scatter, fixed-width
# scatter) run on the engine's own runtime, never on Mojo's stdlib
# `parallelize(...)` pool: that is a second worker-class pool the topology
# scheduler cannot see, pin or govern, and it oversubscribes the box while
# engine workers are still bounded-spinning.
#
# All three dispatch through `runtime_traits/fork_join_shared.fork_join_shared`
# — the SAME shared-payload driver the sort PHASES use — parameterized on
# `D: ParallelDispatch` so `komira_core` never names a concrete dispatcher.
# Each wave carries its own sched-trace SITE_* id so it lands in a NAMED
# SCHED_SITE row rather than the anonymous `SITE_GENERIC_FORK_JOIN` bucket.
#
# THE THREE WAVES ARE NOT FUSED. len -> exclusive-scan -> scatter is a data
# dependency (the scan needs every chunk total; the scatter needs the scan), and
# the fixed-width wave is a different column shape entirely. Each is its own
# fork-join barrier.
#
# CROSS-THREAD SAFETY: workers read the SOURCE offset/data byte buffers BY
# REFERENCE (immutable views taken on the MAIN thread; the raw ptrs live on the
# `SharedChunkWork` struct with CONCRETE origins, no wildcard) and write into
# PRE-ALLOCATED, PRE-SIZED output byte buffers that are MOVED onto the dispatch
# State and reclaimed via `Optional.take()` after the barrier. NO StringArray /
# Column / RecordBatch / ArcPointer-backed type is ever constructed or dropped on
# a worker thread — the output Column is assembled ONCE on the main thread
# (refcount==1) from the filled raw buffers, after the fork-join barrier.


# Gather inner loops below this row count stay SERIAL: the fork-join overhead
# dominates for small gathers (post-agg / post-join sorts are typically tiny).
# 64K-row threshold mirrors the sort path. Callers that need a specific arm
# (tests) pass `gather_parallel_min_rows` explicitly.
comptime GATHER_PARALLEL_MIN_ROWS: Int = 64 * 1024

# A `gather_parallel_min_rows` no gather reaches: forces the SERIAL arm (the
# byte-identity reference for the parallel one).
comptime GATHER_SERIAL_ONLY: Int = Int.MAX


@always_inline
def _on_pool_dispatch_active() -> Bool:
    """True iff an executor-pool dispatch (`run_with_state`) is currently in
    flight on THIS process — i.e. we are running inside a pool worker (e.g. a
    `SortSink.combine_partition` per-partition sort).

    A stdlib `parallelize` fired from inside a live `run_with_state` pool
    LIVELOCKS the dispatcher (nested oversubscription).
    The combine_partition dispatch site brackets its dispatch with
    `komira_on_pool_enter`/`komira_on_pool_exit` (see
    `morsel_segment.on_pool_dispatch_*`); when the depth is > 0 the parallel
    gather stays SERIAL. The per-partition gather already runs ~1/N of the data
    on N pool workers in parallel, so suppressing the inner parallelize loses no
    parallelism — it only prevents the livelock. The `finalize` gather runs
    AFTER the dispatch returns (depth back to 0) and still goes parallel.

    `fork_join_shared` consults the SAME process-global depth and degrades a
    nested wave to INLINE chunks instead of raising or livelocking. This gate
    is nonetheless KEPT, deliberately, so that on-pool callers take the
    hand-written serial arm rather than the (byte-identical but
    differently-shaped) inline chunk loop. The on-pool per-morsel gather is
    the hottest gather in the engine; routing it through the chunk driver is a
    separate, measurable change.

    Reads the process-global atomic depth kept by `komira_core_ffi`'s C shim.
    Cheap (one relaxed atomic load) — paid only when the output is large
    enough to go parallel.
    """
    return external_call["komira_on_pool_depth", Int64]() > Int64(0)


@always_inline
def _gather_nw(count: Int) -> Int:
    """Chunk count for a parallel gather of `count` output rows. Capped at the
    physical core count and at `count` (never more chunks than rows).

    This is the TILING granularity handed to
    `fork_join_shared` as `n_chunks`; the driver derives the actual shard count
    from `dispatcher.worker_count()` and assigns chunks round-robin. Output is
    byte-identical for ANY tiling — `offsets[i]` is the sum of the lengths of
    output rows [0, i) whichever chunk computed each length, because the chunks
    tile [0, count) IN ORDER and `chunk_base` is their exclusive scan."""
    var nw = num_physical_cores()
    if nw < 1:
        nw = 1
    if nw > count:
        nw = count
    if nw < 1:
        nw = 1
    return nw


# =============================================================================
# The three `SharedChunkWork` conformers + their payloads.
# =============================================================================


struct _GatherLenBuf(Movable, Deinitable):
    """Wave-1 shared payload: per-output-row byte length + per-chunk total.

    Pre-sized by the driver (`lengths` to `count`, `chunk_total` to `n_chunks`)
    BEFORE the move onto the dispatch State; chunks only `setitem`.

    Both fields are `Optional` so the driver reclaims them with
    `Optional.take()`. A bare `buf.lengths^` is a partial move out of the
    middle of a value, which Mojo rejects outright ("field destroyed out of the middle of a value")."""

    var lengths: Optional[List[Int32]]
    var chunk_total: Optional[List[Int]]

    def __init__(out self, var lengths: List[Int32], var chunk_total: List[Int]):
        self.lengths = Optional[List[Int32]](lengths^)
        self.chunk_total = Optional[List[Int]](chunk_total^)


struct _GatherStrOut(Movable, Deinitable):
    """Wave-2 shared payload / return value: the finished offsets + data buffers.

    Both are pre-sized before the move (offsets to `(count+1)*4`, or
    `(count+1)*8` when the gather PROMOTED — see `promoted_large`; data to the
    exact total from wave 1), so no chunk can realloc under a peer. `Optional`
    for the same reclaim reason as `_GatherLenBuf` — `Optional.take()`, never a
    partial move.

    `promoted_large` is the OUT-OF-BAND SIGNAL of the Int32-offset promotion.
    It is False for every gather whose byte total fits the promotion threshold
    — i.e. every gather but the >2 GiB one — and when it is
    True the `offsets` buffer holds `(count+1)` **Int64** offsets, so the
    CALLER MUST stamp `LARGE_STRING` / `LARGE_BINARY` on the Column it builds.
    Reading a promoted buffer at Int32 width is exactly the silent wrap this
    machinery exists to prevent, which is why the width is a returned VALUE and
    not a convention: a caller that drops it builds a Column whose tag
    disagrees with its buffers, and `RecordBatch._reject_layout_conflict`
    turns that into a loud error rather than a wrong answer."""

    var offsets: Optional[OwnedAlignedBuffer]
    var data: Optional[OwnedAlignedBuffer]
    var promoted_large: Bool

    def __init__(
        out self,
        var offsets: OwnedAlignedBuffer,
        var data: OwnedAlignedBuffer,
        promoted_large: Bool = False,
    ):
        self.offsets = Optional[OwnedAlignedBuffer](offsets^)
        self.data = Optional[OwnedAlignedBuffer](data^)
        self.promoted_large = promoted_large


@fieldwise_init
struct _GatherStrLenWork[o_off: ImmOrigin](SharedChunkWork):
    """Wave 1 of the variable-width gather: chunk `c` writes `lengths[lo:hi)`
    (its own output rows) and `chunk_total[c]` (its own slot).

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: `chunk_lo` tiles [0, count) exactly, so no two chunks
        touch the same `lengths` element; `chunk_total[c]` is chunk `c`'s
        private slot. The source offsets buffer is READ-ONLY and shared.
      * Liveness: `src_off_ptr` carries the CONCRETE immutable origin of the
        caller's borrowed key column (no wildcard); the fork-join barrier in
        `run_with_state` joins every chunk before the driver returns, so the
        caller's column cannot have been dropped under a worker.
      * No-realloc: both payload lists are sized by the driver before the move.
    """

    # SAFETY: raw source-offsets pointer with a CONCRETE origin pinned to the
    # caller's borrowed column. Read-only; never escapes this module.
    var src_off_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var col_offset: Int
    # Offset into the caller's index list at which THIS gather's output row 0
    # lives. The chunked join terminal passes the ORIGINAL list plus this base
    # rather than a per-chunk copy.
    #
    # ⚠ THIS SHIFTS EXACTLY ONE INDEX SPACE. `index_base` applies ONLY to the
    # index-list read (`idx_ptr`). The OUTPUT arrays — `lengths[i]`,
    # `chunk_total[chunk_id]`, and (in the scatter wave) `offsets[i+1]` and the
    # data slice — are indexed by the chunk-local output row `i` and MUST stay
    # 0-based. Shifting them too is invisible on an INNER join over a
    # non-nullable column, which is why the regression guard drives a
    # NULLABLE string source through >= 3 chunks and asserts NULL POSITIONS.
    var index_base: Int
    var allow_null_sentinel: Bool
    var chunk_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: the driver is instantiated with In=List[Int] (the caller's
        # borrowed `indices`) and P=_GatherLenBuf at the dispatch site below.
        var ip = UnsafePointer(to=input).bitcast[List[Int]]()
        var bp = UnsafePointer(to=payload).bitcast[_GatherLenBuf]()
        # INDEX SPACE: the index list ALONE is windowed. `lp[][i]` and
        # `chunk_total[chunk_id]` below stay 0-based (see `index_base`).
        var idx_ptr = ip[].unsafe_ptr() + self.index_base
        var lp = UnsafePointer(to=bp[].lengths.value())
        var lo = self.chunk_lo[chunk_id]
        var hi = self.chunk_lo[chunk_id + 1]
        var acc = 0
        for i in range(lo, hi):
            var ix = (idx_ptr + i)[]
            if self.allow_null_sentinel and ix == -1:
                # Unmatched outer-join row: zero-length contribution (the
                # offset stays flat, scatter copies nothing). Mirrors the
                # serial join arm's `if idx != -1` guard.
                lp[][i] = Int32(0)
                continue
            var row = self.col_offset + ix
            var start = Int((self.src_off_ptr + row)[])
            var end = Int((self.src_off_ptr + row + 1)[])
            var slen = end - start
            lp[][i] = Int32(slen)
            acc += slen
        bp[].chunk_total.value()[chunk_id] = acc


@fieldwise_init
struct _GatherStrScatterWork[
    o_off: ImmOrigin, o_data: ImmOrigin, l_o: ImmOrigin,
    out_off_dt: DType = DType.int32,
](SharedChunkWork):
    """Wave 2 of the variable-width gather: chunk `c` writes
    `offsets[lo+1 .. hi+1)` and `data[chunk_base[c] .. chunk_base[c+1])`.

    `out_off_dt` IS THE OUTPUT OFFSET WIDTH, AND ONLY THE OUTPUT'S. The SOURCE offsets pointer stays `Int32` — this kernel is
    only ever fed a narrow STRING / BINARY column, and a source that were
    already LARGE_* has no ceiling to escape and takes the serial Int64 arm.
    `DType.int32` is the default; `DType.int64` is reached ONLY from the
    promotion branch in `_parallel_string_gather`, i.e. only where an Int32
    build would overflow. The parameter is comptime, so each arm devirtualizes to a single
    store width and the hot loop gains no branch.

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: the offset slices are disjoint (output rows tile
        [0, count)); the data slices are disjoint because `chunk_base` is the
        exclusive scan of the per-chunk byte totals from wave 1, so
        [chunk_base[c], chunk_base[c+1]) tile [0, total) with no overlap.
        Source buffers + `lengths` are READ-ONLY.
      * Liveness: the two source pointers and the `lengths` reference all carry
        CONCRETE origins tied to driver-frame values that outlive the barrier.
      * No-realloc: `offsets` is sized to `(count+1)*size_of[out_off_dt]` and
        `data` to the exact
        wave-1 total BEFORE the move onto the State.
    """

    # SAFETY: raw source pointers with CONCRETE origins pinned to the caller's
    # borrowed column; read-only, never escape this module.
    var src_off_ptr: UnsafePointer[Scalar[DType.int32], Self.o_off]
    var src_data_ptr: UnsafePointer[Scalar[DType.uint8], Self.o_data]
    # Safe tight-origin reference to the driver's wave-1 length list.
    var lengths: Pointer[List[Int32], Self.l_o]
    var col_offset: Int
    # See `_GatherStrLenWork.index_base`.
    # Applies ONLY to the index-list read. `offsets[i+1]`, `lengths[i]` and the
    # `chunk_base` data slices stay 0-based in the chunk's OUTPUT space.
    var index_base: Int
    var allow_null_sentinel: Bool
    var chunk_lo: List[Int]
    var chunk_base: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: In=List[Int] (borrowed `indices`), P=_GatherStrOut — both
        # fixed at the dispatch site below.
        var ip = UnsafePointer(to=input).bitcast[List[Int]]()
        var bp = UnsafePointer(to=payload).bitcast[_GatherStrOut]()
        # INDEX SPACE: the index list ALONE is windowed (see `index_base`).
        var idx_ptr = ip[].unsafe_ptr() + self.index_base
        # Bind the mutable views to named locals so the origin-tied raw ptrs
        # stay live for the whole chunk body.
        var off_view = bp[].offsets.value().view_mut()
        var dst_off_ptr = off_view._unsafe_ptr().bitcast[
            Scalar[Self.out_off_dt]
        ]()
        var data_view = bp[].data.value().view_mut()
        var dst_data_ptr = data_view._unsafe_ptr()
        var lo = self.chunk_lo[chunk_id]
        var hi = self.chunk_lo[chunk_id + 1]
        var dst_off = self.chunk_base[chunk_id]
        for i in range(lo, hi):
            var ix = (idx_ptr + i)[]
            if self.allow_null_sentinel and ix == -1:
                # Zero-length row (wave 1 already wrote 0): no source read,
                # no copy, offset stays flat.
                (dst_off_ptr + i + 1)[] = Scalar[Self.out_off_dt](dst_off)
                continue
            var row = self.col_offset + ix
            var start = Int((self.src_off_ptr + row)[])
            var slen = Int(self.lengths[][i])
            if slen > 0:
                # `fast_copy_bytes`, NOT stdlib `memcpy` (see the note at the
                # `fast_copy_bytes` import): it cuts this kernel's
                # instructions per string roughly 4x.
                #
                # Non-overlap holds by construction: `dst_data_ptr` is the
                # freshly-allocated output data buffer (sized to the exact
                # wave-1 total) and `src_data_ptr` is the READ-ONLY source
                # column. Spans carry the concrete origins already on the
                # struct / view, so no wildcard-origin cast is introduced.
                #
                # NO OVERRUN: every arm of `fast_copy_bytes` anchors its
                # trailing block at `n - width`, never at a rounded-UP
                # multiple, so neither the loads nor the stores ever touch a
                # byte outside [0, n). The usual "branchless overlapping tail
                # needs slack in the ALLOCATION" caveat therefore does not
                # apply here, and a source string at the very end of an mmap'd
                # page cannot be over-read.
                fast_copy_bytes(
                    Span[UInt8, data_view.origin](
                        unsafe_ptr=dst_data_ptr + dst_off, length=slen
                    ),
                    Span[UInt8, Self.o_data](
                        unsafe_ptr=self.src_data_ptr + start, length=slen
                    ),
                )
            dst_off += slen
            (dst_off_ptr + i + 1)[] = Scalar[Self.out_off_dt](dst_off)
        _ = off_view
        _ = data_view


@fieldwise_init
struct _GatherFixedWork[o_src: ImmOrigin](SharedChunkWork):
    """The fixed-width gather wave: chunk `c` writes output rows
    [chunk_lo[c], chunk_lo[c+1]) == bytes [lo*elem_size, hi*elem_size).

    DISPATCH-BOUNDARY SAFETY:
      * Disjointness: `chunk_lo` tiles [0, count) exactly, so the byte ranges
        are disjoint. The source buffer is READ-ONLY and shared. With
        `allow_null_sentinel`, the buffer is pre-zeroed on the driver thread
        BEFORE the move; chunks only STORE (or skip) into their own slice and
        never read a peer's slot.
      * Liveness: `src_ptr` carries the CONCRETE immutable origin of the
        caller's borrowed column; the barrier joins before the caller returns.
      * No-realloc: `data_buf` is sized + `set_length`'d before the move.
    """

    # SAFETY: raw source byte pointer with a CONCRETE origin pinned to the
    # caller's borrowed column. Read-only; never escapes this module.
    var src_ptr: UnsafePointer[UInt8, Self.o_src]
    var col_offset: Int
    # See `_GatherStrLenWork.index_base`.
    # Applies ONLY to the index-list read; the destination slot `i * elem_size`
    # stays 0-based in the chunk's OUTPUT space.
    var index_base: Int
    var elem_size: Int
    var allow_null_sentinel: Bool
    var chunk_lo: List[Int]

    def process[
        In: Deinitable, P: Movable & Deinitable
    ](
        self, chunk_id: Int, n_chunks: Int, ref input: In, mut payload: P,
    ) raises:
        # SAFETY: In=List[Int] (borrowed `indices`), P=OwnedAlignedBuffer —
        # both fixed at the dispatch site below.
        var ip = UnsafePointer(to=input).bitcast[List[Int]]()
        var bp = UnsafePointer(to=payload).bitcast[OwnedAlignedBuffer]()
        # INDEX SPACE: the index list ALONE is windowed (see `index_base`).
        var idx_ptr = ip[].unsafe_ptr() + self.index_base
        var dst_view = bp[].view_mut()
        var dst_ptr = dst_view._unsafe_ptr()
        var lo = self.chunk_lo[chunk_id]
        var hi = self.chunk_lo[chunk_id + 1]
        var elem_size = self.elem_size
        var col_offset = self.col_offset
        if elem_size == 8:
            var src8 = self.src_ptr.bitcast[Scalar[DType.int64]]()
            var dst8 = dst_ptr.bitcast[Scalar[DType.int64]]()
            for i in range(lo, hi):
                var ix = (idx_ptr + i)[]
                if self.allow_null_sentinel and ix == -1:
                    continue  # leave pre-zeroed slot.
                (dst8 + i)[] = (src8 + col_offset + ix)[]
        elif elem_size == 4:
            var src4 = self.src_ptr.bitcast[Scalar[DType.int32]]()
            var dst4 = dst_ptr.bitcast[Scalar[DType.int32]]()
            for i in range(lo, hi):
                var ix = (idx_ptr + i)[]
                if self.allow_null_sentinel and ix == -1:
                    continue
                (dst4 + i)[] = (src4 + col_offset + ix)[]
        elif elem_size == 2:
            # Widths 2 and 1 get typed arms: in the per-row `memcpy` below a
            # SMALLINT payload would be slower than the BIGINT one it strictly
            # undercuts in useful bytes.
            var src2 = self.src_ptr.bitcast[Scalar[DType.int16]]()
            var dst2 = dst_ptr.bitcast[Scalar[DType.int16]]()
            gather_note_narrow_typed(hi - lo)
            for i in range(lo, hi):
                var ix = (idx_ptr + i)[]
                if self.allow_null_sentinel and ix == -1:
                    continue  # leave pre-zeroed slot.
                (dst2 + i)[] = (src2 + col_offset + ix)[]
        elif elem_size == 1:
            var src1 = self.src_ptr.bitcast[Scalar[DType.int8]]()
            var dst1 = dst_ptr.bitcast[Scalar[DType.int8]]()
            gather_note_narrow_typed(hi - lo)
            for i in range(lo, hi):
                var ix = (idx_ptr + i)[]
                if self.allow_null_sentinel and ix == -1:
                    continue  # leave pre-zeroed slot.
                (dst1 + i)[] = (src1 + col_offset + ix)[]
        else:
            # ⛔ THE PER-ROW `memcpy` SURVIVES AND MUST: DECIMAL128 and
            # INTERVAL_MONTH_DAY_NANO are 16 bytes, DECIMAL256 is 32, and none
            # has a typed arm. The invariant is "no fallback at width 1 or 2".
            gather_note_width_fallback(hi - lo, elem_size)
            for i in range(lo, hi):
                var ix = (idx_ptr + i)[]
                if self.allow_null_sentinel and ix == -1:
                    continue
                var s_off = (col_offset + ix) * elem_size
                unsafe_memcpy(
                    dest=dst_ptr + i * elem_size,
                    src=self.src_ptr + s_off,
                    count=elem_size,
                )
        _ = dst_view


# =============================================================================
# The three wave runners.
# =============================================================================
#
# One thin function per wave. They exist so the raw pointers' ORIGINS can be
# INFERRED from the arguments (`o_off` / `o_data` / `l_o` / `o_src`) while
# `has_pool` / `D` / `disp_o` are passed by keyword. That is the in-tree idiom
# from `parallel_column_sort._parallel_string_perm`: a `view_ro()._unsafe_ptr()`
# carries the origin of the underlying BUFFER, not of the view local, so the
# origin cannot be spelled at the construction site — it has to arrive through a
# parameter the compiler unifies against the argument. No wildcard origin, no
# `unsafe_origin_cast`, nothing spelled by hand.


def _run_gather_len_wave[
    o_off: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    src_off_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    imm indices: List[Int],
    col_offset: Int,
    allow_null_sentinel: Bool,
    var chunk_lo: List[Int],
    var payload: _GatherLenBuf,
    n_chunks: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    index_base: Int = 0,
) raises -> _GatherLenBuf:
    """Wave 1: per-output-row byte lengths + per-chunk totals."""
    var work = _GatherStrLenWork[o_off](
        src_off_ptr,
        col_offset,
        index_base,
        allow_null_sentinel,
        chunk_lo^,
    )
    return fork_join_shared[
        _GatherStrLenWork[o_off],
        List[Int],
        _GatherLenBuf,
        origin_of(indices),
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        indices,
        payload^,
        n_chunks,
        2,
        0,
        dispatcher_ptr,
        CancellationToken.never(),
        SITE_GATHER_STR_LEN,
    )


def _run_gather_scatter_wave[
    o_off: ImmOrigin,
    o_data: ImmOrigin,
    l_o: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
    out_off_dt: DType = DType.int32,
](
    src_off_ptr: UnsafePointer[Scalar[DType.int32], o_off],
    src_data_ptr: UnsafePointer[UInt8, o_data],
    ref [l_o] lengths: List[Int32],
    imm indices: List[Int],
    col_offset: Int,
    allow_null_sentinel: Bool,
    var chunk_lo: List[Int],
    var chunk_base: List[Int],
    var payload: _GatherStrOut,
    n_chunks: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    index_base: Int = 0,
) raises -> _GatherStrOut:
    """Wave 2: offsets fill + byte scatter into the pre-sized output buffers.

    `out_off_dt` selects the OUTPUT offset store width and defaults to
    `DType.int32`. See
    `_GatherStrScatterWork` for why the source width is not parameterised."""
    var work = _GatherStrScatterWork[o_off, o_data, l_o, out_off_dt](
        src_off_ptr,
        src_data_ptr,
        Pointer(to=lengths),
        col_offset,
        index_base,
        allow_null_sentinel,
        chunk_lo^,
        chunk_base^,
    )
    return fork_join_shared[
        _GatherStrScatterWork[o_off, o_data, l_o, out_off_dt],
        List[Int],
        _GatherStrOut,
        origin_of(indices),
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        indices,
        payload^,
        n_chunks,
        2,
        0,
        dispatcher_ptr,
        CancellationToken.never(),
        SITE_GATHER_STR_SCATTER,
    )


def _run_gather_fixed_wave[
    o_src: ImmOrigin,
    has_pool: Bool,
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    src_ptr: UnsafePointer[UInt8, o_src],
    imm indices: List[Int],
    col_offset: Int,
    elem_size: Int,
    allow_null_sentinel: Bool,
    var chunk_lo: List[Int],
    var payload: OwnedAlignedBuffer,
    n_chunks: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    index_base: Int = 0,
) raises -> OwnedAlignedBuffer:
    """The fixed-width wave: indexed scatter into the pre-sized data buffer."""
    var work = _GatherFixedWork[o_src](
        src_ptr,
        col_offset,
        index_base,
        elem_size,
        allow_null_sentinel,
        chunk_lo^,
    )
    return fork_join_shared[
        _GatherFixedWork[o_src],
        List[Int],
        OwnedAlignedBuffer,
        origin_of(indices),
        D,
        has_pool=has_pool,
        disp_o=disp_o,
    ](
        work^,
        indices,
        payload^,
        n_chunks,
        2,
        0,
        dispatcher_ptr,
        CancellationToken.never(),
        SITE_GATHER_FIXEDWIDTH,
    )


def _parallel_string_gather[
    has_pool: Bool, D: ParallelDispatch, disp_o: Origin[mut=True],
](
    imm col_ref: Column[HeapRegion],
    indices: List[Int],
    count: Int,
    var new_offsets: OwnedAlignedBuffer,
    nw: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    allow_null_sentinel: Bool = False,
    column_name: String = String(),
    index_base: Int = 0,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> _GatherStrOut:
    """Two-pass variable-width (STRING / BINARY) gather on the engine runtime.

    ⚠ THE RETURNED OFFSET WIDTH IS DATA-DEPENDENT — READ `promoted_large`.
    When the gathered total exceeds `offset_promote_at` (production:
    `ARROW_INT32_OFFSET_MAX`) this emits **Int64** offsets and sets
    `_GatherStrOut.promoted_large` rather than raising. A caller that builds a
    Column from this pair MUST widen the tag to `LARGE_STRING` / `LARGE_BINARY` when
    the flag is set. `new_offsets` is passed in sized for Int32 and is
    REPLACED, not grown, on the promoted path — do not assume the buffer you
    handed in is the buffer you get back.

    Pass 1 (parallel length + chunk-local totals -> exclusive scan): each chunk
    computes the byte length of every output row in its disjoint range [lo, hi)
    and the chunk's total. The chunk totals are exclusive-scanned SERIALLY on the
    driver thread (nw entries, trivial), giving each chunk its starting output
    byte offset.

    Pass 2 (parallel offsets fill + scatter): each chunk memcpy's its rows'
    source bytes from `data[src_start..src_end)` into the freshly-allocated data
    buffer at the computed output offset, and fills its slice of the offsets
    buffer from its chunk base — producing the EXACT cumulative offsets the serial
    gather produces (no off-by-one: offset[i] = sum of lengths of output rows
    [0, i)).

    THE TWO PASSES ARE NOT FUSED — pass 2 needs the exclusive scan of pass 1's
    per-chunk totals, which needs every chunk to have finished. Two barriers.

    `new_offsets` is MOVED IN sized to `(count+1)*4` bytes and returned inside
    the `_GatherStrOut` pair together with the data buffer, which is ALLOCATED
    here at the total byte count computed in pass 1. Both are MOVED onto the
    dispatch State for each wave and reclaimed after the barrier via
    `Optional.take()` (never a partial move) — no borrowed mutable buffer ever
    crosses the barrier.

    Byte-identical to the serial STRING arm in `gather_batch`.

    Both waves dispatch through `runtime_traits/fork_join_shared` onto the
    caller's `D: ParallelDispatch`, each with its own sched-trace site id.
    `has_pool=False` prunes the dispatch entirely and runs the chunks inline
    (byte-identical).

    NULL-SENTINEL: the JOIN-output assemble reuses this kernel
    for LEFT/FULL outer joins where an unmatched row's index is `-1` (no source
    row). When `allow_null_sentinel` is True, a `-1` index contributes a
    ZERO-length output row (the offset stays flat, no bytes copied) — byte-
    identical to the serial join STRING arm's `if idx != -1` guard
    (`compiler_join_assembly.emit_gather_column_projected`). The SORT/FILTER
    callers leave `allow_null_sentinel=False` (their permutations never contain
    `-1`), so the sort path stays byte-unchanged and the `-1` check is never
    executed for them.

    INDEX WINDOW: this gather reads `indices[index_base : index_base + count]`
    and writes OUTPUT rows `[0, count)`. `index_base` defaults to 0 for every
    SORT / FILTER / `gather_batch` caller; only the chunked join terminal
    passes a non-zero base, so it need not copy a per-chunk index list."""
    comptime int32_size = size_of[Int32]()
    comptime int64_size = size_of[Int64]()

    # ---- Driver-thread setup: source views + chunk boundaries. ----
    var src_offsets_view = col_ref._offsets.value().view_ro()
    var src_off_ptr = src_offsets_view._unsafe_ptr().bitcast[
        Scalar[DType.int32]
    ]()
    var src_data_view = col_ref._data.view_ro()
    var src_data_ptr = src_data_view._unsafe_ptr()
    var col_offset = col_ref._offset

    # nw contiguous chunks tile [0, count).
    var chunk_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        chunk_lo.append((p * count) // nw)

    # Per-output-row byte length + per-chunk total: the wave-1 shared payload,
    # PRE-SIZED here (no chunk ever appends). The lengths are ZERO-FILLED on
    # the driver even though wave 1 writes every element (both arms of
    # `_GatherStrLenWork.process` store, and `chunk_lo` tiles `[0, count)`
    # exactly): an uninitialised `resize` would hand back a recycled
    # allocation whose slots hold plausible in-range values, so any future
    # coverage gap would be a SILENT WRONG ANSWER rather than a zero.
    var lengths = List[Int32](capacity=count)
    for _ in range(count):
        lengths.append(Int32(0))
    var chunk_total = List[Int](capacity=nw)
    for _ in range(nw):
        chunk_total.append(0)

    # ---- WAVE 1: lengths + per-chunk totals. ----
    # SAFETY block lives on `_GatherStrLenWork` (Disjointness / Liveness /
    # No-realloc), which is the type that owns the raw pointers. `o_off` is
    # INFERRED from `src_off_ptr` (the in-tree sort idiom — see
    # `parallel_column_sort._parallel_string_perm`); has_pool / D / disp_o are
    # passed by keyword so the inference slot stays open.
    var len_buf = _run_gather_len_wave[
        has_pool=has_pool, D=D, disp_o=disp_o
    ](
        src_off_ptr,
        indices,
        col_offset,
        allow_null_sentinel,
        chunk_lo.copy(),
        _GatherLenBuf(lengths^, chunk_total^),
        nw,
        dispatcher_ptr,
        index_base,
    )
    # Reclaim via Optional.take — NOT a partial move.
    var out_lengths = len_buf.lengths.take()
    var out_totals = len_buf.chunk_total.take()
    _ = len_buf^

    # ---- Serial exclusive scan of chunk totals (nw entries). ----
    var chunk_base = List[Int](capacity=nw + 1)
    var running = 0
    for p in range(nw):
        chunk_base.append(running)
        running += out_totals[p]
    chunk_base.append(running)
    var total_data_bytes = running

    # ==================================================================
    # THE INT32-OFFSET CEILING — A PROMOTION DECISION, NOT A RAISE.
    #
    # Wave 1 accumulated `total_data_bytes` in 64-bit `Int`; wave 2 narrows
    # every cumulative offset to the OUTPUT width. Decide the width HERE —
    # before the data buffer is allocated and before a single offset is
    # written, at O(1) cost.
    #
    # Above the threshold this emits Int64 offsets and the caller stamps
    # `LARGE_STRING` / `LARGE_BINARY`. The choice being made is between a
    # `large_string` result and NO result — there is no narrow-typed answer
    # being given up, because at these byte counts a narrow answer does not
    # exist. Nothing here ever writes a wrapped offset.
    #
    # ⚠ THE FIRE IS ANNOUNCED, ALWAYS. The promotion changes the DECLARED
    # type of a user-visible column, so it must never be silent — a reader who
    # gets `large_string` back from a query that has always said `string` has
    # to be able to find out why from the run itself and not from this
    # comment. Unconditional is affordable precisely because the event is
    # rare: one line per >2 GiB column.
    var promote_large = should_promote_offsets(
        total_data_bytes, offset_promote_at
    )
    if promote_large:
        print(
            "ArrowOffsetPromotion: column '"
            + column_name
            + "' at _parallel_string_gather needs "
            + String(total_data_bytes)
            + " data bytes for "
            + String(count)
            + " values, which exceeds the Arrow 32-bit offset limit of "
            + String(ARROW_INT32_OFFSET_MAX)
            + ". PROMOTING this column to 64-bit offsets (large_string /"
            + " large_binary). Its declared Arrow type widens accordingly;"
            + " Parquet / Arrow-IPC / C-Data exports carry the wide type.",
            file=_STDERR,
        )

    var out_off_size = int64_size if promote_large else int32_size

    # Allocate the data buffer at the EXACT total computed in pass 1 (ctor
    # post-condition sets _length == capacity, so chunk writes through the raw
    # ptr land within bounds). `new_offsets` arrives sized for Int32 by the
    # caller's ctor; a PROMOTED gather needs twice that, and `set_length`
    # cannot grow past the allocation, so the wide case takes a fresh buffer.
    var new_data = OwnedAlignedBuffer(max(total_data_bytes, 1))
    if promote_large:
        new_offsets = OwnedAlignedBuffer((count + 1) * int64_size)
    if Int(new_offsets._length) < (count + 1) * out_off_size:
        new_offsets.set_length(Int64((count + 1) * out_off_size))

    # offsets[0] = 0 (Arrow contract) — written on the DRIVER thread before the
    # move.
    if promote_large:
        new_offsets.set_typed[Int64](0, Int64(0))
    else:
        new_offsets.set_typed[Int32](0, Int32(0))

    # ---- WAVE 2: offsets fill + byte scatter. ----
    # `o_off` / `o_data` / `l_o` are INFERRED from the two source pointers and
    # the borrowed `out_lengths`; has_pool / D / disp_o are keyword-explicit.
    # `out_off_dt` is COMPTIME, so the two arms below are two instantiations
    # of one kernel, each with a single devirtualized store width.
    var out_pair: _GatherStrOut
    if promote_large:
        out_pair = _run_gather_scatter_wave[
            has_pool=has_pool, D=D, disp_o=disp_o, out_off_dt = DType.int64
        ](
            src_off_ptr,
            src_data_ptr,
            out_lengths,
            indices,
            col_offset,
            allow_null_sentinel,
            chunk_lo.copy(),
            chunk_base.copy(),
            _GatherStrOut(new_offsets^, new_data^, promoted_large=True),
            nw,
            dispatcher_ptr,
            index_base,
        )
    else:
        out_pair = _run_gather_scatter_wave[
            has_pool=has_pool, D=D, disp_o=disp_o
        ](
            src_off_ptr,
            src_data_ptr,
            out_lengths,
            indices,
            col_offset,
            allow_null_sentinel,
            chunk_lo.copy(),
            chunk_base.copy(),
            _GatherStrOut(new_offsets^, new_data^),
            nw,
            dispatcher_ptr,
            index_base,
        )
    _ = chunk_base^
    _ = out_lengths^
    _ = src_offsets_view
    _ = src_data_view

    # Set the logical lengths to match the serial arm (ctor over-allocated to a
    # padded capacity; the Column reads `_length`).
    var done_off = out_pair.offsets.take()
    var done_data = out_pair.data.take()
    _ = out_pair^
    # `out_off_size` — NOT `int32_size`. A promoted buffer whose logical length
    # said `(count+1)*4` would present `LARGE_STRING` offsets truncated to half
    # their rows, which reads as a short column rather than an error.
    done_off.set_length(Int64((count + 1) * out_off_size))
    done_data.set_length(Int64(total_data_bytes))
    return _GatherStrOut(done_off^, done_data^, promoted_large=promote_large)


def _parallel_fixedwidth_gather[
    has_pool: Bool, D: ParallelDispatch, disp_o: Origin[mut=True],
](
    imm col_ref: Column[HeapRegion],
    indices: List[Int],
    count: Int,
    elem_size: Int,
    var data_buf: OwnedAlignedBuffer,
    nw: Int,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    allow_null_sentinel: Bool = False,
    index_base: Int = 0,
) raises -> OwnedAlignedBuffer:
    """Fixed-width (int / float / bool / decimal) indexed scatter on the engine
    runtime.

    Each chunk copies `elem_size` bytes per output row in its disjoint range
    [lo, hi) from the source `_data` buffer (honoring `_offset`) into `data_buf`
    at `i * elem_size`. 8-byte and 4-byte element widths use direct typed stores
    (matching the serial hot path); other widths use `memcpy`. `data_buf` is
    MOVED IN sized to `count * elem_size`, MOVED onto the dispatch State for the
    wave, and returned. Byte-identical to the serial fixed-width arm in
    `gather_batch`.

    It dispatches through `runtime_traits/fork_join_shared` onto the caller's
    `D: ParallelDispatch` under its own sched-trace site id. `has_pool=False`
    prunes the dispatch and runs the chunks inline (byte-identical).

    NULL-SENTINEL: the JOIN-output assemble reuses this kernel
    for nullable outer-join sides where an unmatched row's index is `-1`. When
    `allow_null_sentinel` is True, the data buffer is ZEROED on the driver thread
    before dispatch and chunks SKIP the store for a `-1` index, leaving its slot
    zero — byte-identical to the serial join nullable fixed-width arm
    (`fill(0)` + `if idx == -1: bm.clear(i)`). The validity bitmap is resolved
    SEPARATELY on the main thread by the caller (NOT here — this kernel only
    writes the data buffer). The SORT/FILTER callers leave
    `allow_null_sentinel=False`, so their path stays byte-unchanged.

    INDEX WINDOW: reads `indices[index_base : index_base + count]`, writes
    OUTPUT slots `[0, count)`. `index_base=0` is the default — see
    `_parallel_string_gather`."""
    var src_data_view = col_ref._data.view_ro()
    var src_ptr = src_data_view._unsafe_ptr()
    var col_offset = col_ref._offset

    if Int(data_buf._length) < count * elem_size:
        data_buf.set_length(Int64(count * elem_size))
    # NULL-SENTINEL: pre-zero the data buffer on the DRIVER thread so a `-1`
    # (skipped) slot reads as zero — mirrors the serial nullable arm's
    # `data_buf.view_range_mut(0, count*elem_size).fill(0)`. Done before the
    # dispatch so no chunk has to zero (and so chunks only ever STORE, never
    # conditionally-skip-into-uninitialized memory).
    if allow_null_sentinel:
        data_buf.view_range_mut(0, count * elem_size).fill(0)

    var chunk_lo = List[Int](capacity=nw + 1)
    for p in range(nw + 1):
        chunk_lo.append((p * count) // nw)

    # SAFETY block lives on `_GatherFixedWork` (Disjointness / Liveness /
    # No-realloc), which is the type that owns the raw source pointer. `o_src` is
    # INFERRED from `src_ptr`; has_pool / D / disp_o are keyword-explicit.
    var out = _run_gather_fixed_wave[
        has_pool=has_pool, D=D, disp_o=disp_o
    ](
        src_ptr,
        indices,
        col_offset,
        elem_size,
        allow_null_sentinel,
        chunk_lo^,
        data_buf^,
        nw,
        dispatcher_ptr,
        index_base,
    )
    _ = src_data_view

    # Match the serial arm's logical-length finalization.
    var done = out^
    done.set_length(Int64(count * elem_size))
    return done^


def gather_batch(batch: RecordBatch, indices: List[Int]) raises -> RecordBatch:
    """Gather selected rows from a RecordBatch into a new RecordBatch — SERIAL.

    This is the dispatcher-less entry point: it forwards to
    `gather_batch_dispatch` with comptime `has_pool=False`, so the per-column
    gather runs on the calling thread.

    READ THIS BEFORE ADDING A NEW CALLER. The gather kernels never use Mojo's
    stdlib `parallelize(...)` pool (a second worker-class pool the topology
    scheduler cannot see, pin or govern), so a gather can only be parallel if
    its caller THREADS A DISPATCHER — and this 2-arg entry is honestly serial.

    It is the right entry for a caller running ON a pool worker (its gather is
    suppressed to serial by `_on_pool_dispatch_active` anyway) or for a caller
    whose gathers are small. A caller that gathers >= 64K rows OFF-pool should
    reach `gather_batch_dispatch` with its dispatcher instead.

    Handles both fixed-width types (int, float, bool) and variable-length
    types (string). For string columns, rebuilds the offsets and data buffers
    by copying each selected string's bytes.
    """
    # Class C serial-fallback shape: substitute D=NoDispatch with a CONCRETE
    # origin (`origin_of` a stack-local), NOT a MutAnyOrigin wildcard. The
    # Optional is always None and `has_pool=False` prunes the dispatch branch, so
    # the pointer is a never-dereferenced phantom — but an ASAP-trackable one.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return gather_batch_dispatch[False, NoDispatch, nd_o](
        batch, indices, Optional[Pointer[NoDispatch, nd_o]](None)
    )


def gather_batch_dispatch[
    has_pool: Bool, D: ParallelDispatch, disp_o: Origin[mut=True],
](
    batch: RecordBatch,
    indices: List[Int],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    gather_parallel_min_rows: Int = GATHER_PARALLEL_MIN_ROWS,
    offset_promote_at: Int = ARROW_INT32_OFFSET_MAX,
) raises -> RecordBatch:
    """Gather selected rows from a RecordBatch into a new RecordBatch.

    Handles fixed-width types, the offsets-carrying variable-length types
    (STRING / BINARY / LARGE_STRING / LARGE_BINARY), DICTIONARY, and the
    nested / union layouts. For a variable-length column it rebuilds the
    offsets and data buffers by copying each selected value's bytes.

    BOOL is handled by a bit-packed arm (never by the fixed-width fallthrough,
    which would read a bit-packed buffer at byte width).

    When the caller threaded a dispatcher (`has_pool=True`) and the output is
    large enough (>= `gather_parallel_min_rows`, default
    `GATHER_PARALLEL_MIN_ROWS`), the per-column STRING two-pass and
    fixed-width scatter run in parallel on the engine runtime. Byte-identical
    to the serial gather. See `_parallel_string_gather` /
    `_parallel_fixedwidth_gather` for the cross-thread safety contract. Tests
    pass `gather_parallel_min_rows=1` to force the parallel arm and
    `GATHER_SERIAL_ONLY` for the serial reference.

    `offset_promote_at` is the data-byte count above which a variable-width
    output column is promoted to 64-bit offsets (production:
    `ARROW_INT32_OFFSET_MAX`).

    `D` is the caller's concrete dispatcher, so the `run_with_state` calls
    DEVIRTUALIZE per instantiation. An engine-side caller holding a
    `SharedForkJoinHandle` passes `handle.ptr` straight through — that is how a core kernel gets the pool without
    `komira_core` naming `LocalDispatcher` (which lives up in
    `komira_async`).
    """
    var count = len(indices)
    var num_cols = batch.num_columns()

    # SAFETY: Extract raw pointer from indices List to bypass per-element bounds
    # checks in the gather loops. Indices are produced by filter_to_indices or
    # join probe and are guaranteed to be valid row indices.
    var idx_ptr = indices.unsafe_ptr()

    # Route the per-column STRING two-pass + fixed-width scatter through the
    # parallel helpers when the output is large enough to amortize the
    # fork-join. Decided ONCE for the whole batch.
    #
    # SUPPRESS the parallel gather when an executor-pool dispatch is in flight
    # (`_on_pool_dispatch_active`). The on-pool caller is
    # `SortSink.combine_partition`'s per-partition sort, which already runs
    # ~1/N of the data on N pool workers in parallel; the `finalize` gather
    # (off-pool, depth==0) still goes parallel. See
    # `_on_pool_dispatch_active`'s docstring for why the gate is kept.
    #
    # Without a threaded dispatcher there is nothing to dispatch onto, so a
    # `has_pool=False` instantiation is serial at comptime and the row-count
    # read below folds away.
    var gather_parallel = (
        has_pool
        and count >= gather_parallel_min_rows
        and not _on_pool_dispatch_active()
    )
    # Chunk count. Hardware-derived from the DISPATCHER's pool when we have one
    # (house rule: never a constant), falling back to `_gather_nw`'s physical-core
    # cap. Capped at `count` so a tiny gather never has empty chunks.
    var gather_nw = 1
    if gather_parallel:
        gather_nw = _gather_nw(count)

        comptime if has_pool:
            var wc = dispatcher_ptr.value()[].worker_count()
            if wc >= 1 and wc < gather_nw:
                gather_nw = wc

    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    for c in range(num_cols):
        # Preserve the full Field metadata through filter / sort gather. The
        # bare 3-arg Field ctor would strip tz / decimal (p,s) / dict-idx / flags / kv-metadata.
        sb.add_field(batch.schema.field_at(c))
        ref col_ref = batch.column_at(c)
        var at = col_ref.arrow_type

        # --- Validity bitmap (common to all column types) ---
        var validity = Optional[Bitmap[HeapRegion]](None)
        var null_count = 0
        if col_ref._validity:
            var bm = Bitmap.create(count)
            for i in range(count):
                if not col_ref._validity.value().test(col_ref._offset + (idx_ptr + i)[]):
                    bm.clear(i)
                    null_count += 1
                else:
                    bm.set(i)
            validity = bm^

        # Nested types (LIST/STRUCT/MAP) and unions own children + auxiliary
        # slots that the per-DType branches below do not preserve; in the
        # `else: fixed-width` branch they would produce a Column with the
        # right arrow_type but garbage `_data` and ZERO children/type_ids.
        # `copy_column` delegates to `Column.deep_copy()`; gather_batch
        # delegates to the union compute kernel (which handles both union +
        # recursive nested children via _take_column_dispatch).
        if (
            at == ArrowType.LIST
            or at == ArrowType.STRUCT
            or at == ArrowType.MAP
            or at == ArrowType.UNION_SPARSE
            or at == ArrowType.UNION_DENSE
        ):
            # Lift indices List[Int] back from the raw ptr.  The
            # `indices` parameter is already in scope.
            var nested_indices = List[Int](capacity=count)
            for i in range(count):
                nested_indices.append((idx_ptr + i)[])
            if at == ArrowType.UNION_SPARSE or at == ArrowType.UNION_DENSE:
                builder.add_column(take_union(col_ref, nested_indices))
            else:
                # LIST / STRUCT / MAP — delegate to the per-type take
                # helper in union_compute.  (MapArray is internally a
                # list<entries: struct<key, value>> per Arrow spec, so
                # _take_list handles it correctly.)
                builder.add_column(_take_column_dispatch(col_ref, nested_indices))
            continue

        if at == ArrowType.DICTIONARY:
            # Dictionary column: gather only the CODES, share the dict (copy the
            # dict values once, not per row). Much cheaper than gathering the
            # resolved values. Handles BOTH the string dict shape (int32 codes +
            # string offsets + packed bytes) AND the NUMERIC dict shape (int32/int64 codes + flat numeric dict-values
            # buffer, NO offsets). The numeric shape is discriminated by
            # `is_numeric_dict()`. PERF-CRITICAL origin-tied pointer drop-in.
            comptime int32_size = size_of[Int32]()
            comptime _DICT_PF: Int = 16
            var code_w = col_ref._dict_index_byte_width
            var dict_off = col_ref._offset

            # Gather the codes at the column's code byte width.
            var src_code_view = col_ref._data.view_ro()
            var new_code_buf: OwnedAlignedBuffer
            if code_w == 8:
                var src_c64 = src_code_view._unsafe_ptr().bitcast[
                    Scalar[DType.int64]
                ]()
                var code_bytes = count * 8
                new_code_buf = OwnedAlignedBuffer(max(code_bytes, 1))
                var dst_v = new_code_buf.view_mut()
                var dst_c64 = dst_v._unsafe_ptr().bitcast[Scalar[DType.int64]]()
                for i in range(count):
                    (dst_c64 + i)[] = (src_c64 + dict_off + (idx_ptr + i)[])[]
                new_code_buf.set_length(Int64(code_bytes))
            else:
                var src_c32 = src_code_view._unsafe_ptr().bitcast[
                    Scalar[DType.int32]
                ]()
                var code_bytes = count * int32_size
                new_code_buf = OwnedAlignedBuffer(max(code_bytes, 1))
                var dst_v = new_code_buf.view_mut()
                var dst_c32 = dst_v._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                for i in range(count):
                    if i + _DICT_PF < count:
                        prefetch[
                            params = PrefetchOptions()
                            .for_read()
                            .high_locality()
                        ](
                            (
                                src_c32
                                + dict_off
                                + (idx_ptr + i + _DICT_PF)[]
                            ).bitcast[Scalar[DType.int64]]()
                        )
                    (dst_c32 + i)[] = (src_c32 + dict_off + (idx_ptr + i)[])[]
                new_code_buf.set_length(Int64(code_bytes))

            # Copy the shared dict-values buffer once (numeric: flat values;
            # string: packed UTF-8 bytes). Both live in `_dict_data`.
            var dict_data_len = col_ref._dict_data.value().len()
            var new_dict_data = OwnedAlignedBuffer(max(dict_data_len, 1))
            if dict_data_len > 0:
                new_dict_data.copy_from_view(
                    col_ref._dict_data.value().view_range_ro(0, dict_data_len)
                )
            new_dict_data.set_length(Int64(dict_data_len))

            var new_offsets: Optional[OwnedAlignedBuffer] = None
            if not col_ref.is_numeric_dict():
                # String dict: copy the shared dictionary offsets too.
                var dict_offsets_bytes = (col_ref._dict_size + 1) * int32_size
                var nfo = OwnedAlignedBuffer(dict_offsets_bytes)
                nfo.copy_from_view(
                    col_ref._offsets.value().view_range_ro(0, dict_offsets_bytes)
                )
                nfo.set_length(Int64(dict_offsets_bytes))
                new_offsets = nfo^

            var new_col = Column[HeapRegion](
                arrow_type=ArrowType.DICTIONARY,
                data=new_code_buf^,
                offsets=new_offsets^,
                validity=validity^,
                length=count,
                null_count=null_count,
                offset=0,
            )
            new_col._set_dict_data_from_oab(new_dict_data^)
            new_col._dict_size = col_ref._dict_size
            new_col._dict_index_byte_width = code_w
            new_col._dict_value_dtype = col_ref._dict_value_dtype
            builder.add_column(new_col^)
        elif at == ArrowType.STRING or at == ArrowType.BINARY:
            # Variable-length string / binary column: rebuild offsets + data buffers.
            # STRING and BINARY share the identical (offsets, bytes, validity)
            # physical layout; offsets/data go through the typed view API.
            if not col_ref._offsets:
                raise Error(
                    "_gather_batch: variable-length column missing offsets buffer"
                    " (arrow_type=" + String(at) + ")"
                )
            comptime int32_size = size_of[Int32]()
            comptime int64_size = size_of[Int64]()
            var new_offsets: OwnedAlignedBuffer
            var new_data: OwnedAlignedBuffer
            # OFFSET-WIDTH PROMOTION. Set by
            # whichever of the two arms below produced the buffers; the tag
            # stamped on the output Column follows it. Declared WITHOUT an
            # initializer on purpose: both arms assign it, so a `= False` here
            # is a dead store, and leaving it uninitialized makes the compiler
            # the check that neither arm can fall through unset.
            var promoted: Bool

            if gather_parallel:
                # Parallel two-pass: length+offsets prefix-scan, then scatter,
                # each its own `run_with_state` wave on the engine runtime.
                # Allocates
                # + fills BOTH buffers (they are MOVED onto the dispatch State
                # and reclaimed after the barrier; cross-thread safety: source
                # RO, output pre-sized; NO StringArray/ArcPointer on a worker).
                # Byte-identical.
                var pair = _parallel_string_gather[has_pool, D, disp_o](
                    col_ref,
                    indices,
                    count,
                    OwnedAlignedBuffer((count + 1) * int32_size),
                    gather_nw,
                    dispatcher_ptr,
                    column_name=batch.schema.field_name(c),
                    offset_promote_at=offset_promote_at,
                )
                new_offsets = pair.offsets.take()
                new_data = pair.data.take()
                promoted = pair.promoted_large
                _ = pair^
            else:
                var src_offsets_view = col_ref._offsets.value().view_ro()

                # First pass: compute total data bytes needed
                var total_data_bytes = 0
                for i in range(count):
                    var row = col_ref._offset + (idx_ptr + i)[]
                    var start = Int(src_offsets_view.get_typed[Int32](row))
                    var end = Int(src_offsets_view.get_typed[Int32](row + 1))
                    total_data_bytes += end - start

                # THE INT32-OFFSET CEILING — serial twin of the promotion
                # decision in `_parallel_string_gather`. Made before the
                # allocation and before pass 2's narrowing, so no wrapped
                # offset is ever written on either arm.
                promoted = should_promote_offsets(
                    total_data_bytes, offset_promote_at
                )
                if promoted:
                    print(
                        "ArrowOffsetPromotion: column '"
                        + batch.schema.field_name(c)
                        + "' at _gather_batch(serial string) needs "
                        + String(total_data_bytes)
                        + " data bytes for "
                        + String(count)
                        + " values, which exceeds the Arrow 32-bit offset"
                        + " limit of "
                        + String(ARROW_INT32_OFFSET_MAX)
                        + ". PROMOTING this column to 64-bit offsets"
                        + " (large_string / large_binary). Its declared Arrow"
                        + " type widens accordingly; Parquet / Arrow-IPC /"
                        + " C-Data exports carry the wide type.",
                        file=_STDERR,
                    )
                var out_off_w = int64_size if promoted else int32_size
                new_offsets = OwnedAlignedBuffer((count + 1) * out_off_w)

                # Allocate the data buffer (offsets already allocated above).
                new_data = OwnedAlignedBuffer(max(total_data_bytes, 1))

                # Second pass: copy string bytes and fill offsets. Two arms at
                # two store widths, hoisted out of the loop — see the join
                # assemble's serial arm for why the branch is not per-row.
                var dst_offset = 0
                new_offsets.set_length(Int64((count + 1) * out_off_w))
                if promoted:
                    new_offsets.set_typed[Int64](0, Int64(0))
                else:
                    new_offsets.set_typed[Int32](0, Int32(0))
                for i in range(count):
                    var row = col_ref._offset + (idx_ptr + i)[]
                    var start = Int(src_offsets_view.get_typed[Int32](row))
                    var end = Int(src_offsets_view.get_typed[Int32](row + 1))
                    var str_len = end - start
                    if str_len > 0:
                        new_data.view_range_mut(
                            dst_offset, str_len
                        ).copy_from_view_at(
                            0, col_ref._data.view_range_ro(start, str_len)
                        )
                    dst_offset += str_len
                    if promoted:
                        new_offsets.set_typed[Int64](i + 1, Int64(dst_offset))
                    else:
                        new_offsets.set_typed[Int32](i + 1, Int32(dst_offset))

                new_data.set_length(Int64(total_data_bytes))
                _ = src_offsets_view


            # Tag follows buffer. `widen_offset_type` maps STRING ->
            # LARGE_STRING and BINARY -> LARGE_BINARY; the SCHEMA is promoted
            # in lockstep by `RecordBatchBuilder.build`.
            var out_at_g = widen_offset_type(at) if promoted else at
            var new_col = Column[HeapRegion](
                arrow_type=out_at_g,
                data=new_data^,
                offsets=new_offsets^,
                validity=validity^,
                length=count,
                null_count=null_count,
                offset=0,
            )
            builder.add_column(new_col^)
        elif at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY:
            # ELEMENT-SIZE WIDTH GUARD. LARGE_* must not fall through to the
            # fixed-width `else` below: that would allocate `count * 8` bytes,
            # memcpy them out of the UTF-8 PAYLOAD buffer at byte offset
            # `row * 8`, and build a right-length column with `offsets=None`
            # -- garbage bytes that a row-count assertion passes clean.
            # `arrow_types.arrow_fixed_byte_width` refuses a variable-width
            # type, so such an input would raise.
            #
            # This is the Int64-offset mirror of the STRING / BINARY arm above.
            # NO parallel branch: `_parallel_string_gather` hard-codes Int32
            # offsets end to end (its prefix-scan buffer is
            # `(count + 1) * int32_size` and it narrows with `Int32(...)`), so
            # LARGE_* takes the serial two-pass path unconditionally. That is a
            # throughput choice, never a correctness one — and it is the reason
            # there is no `check_int32_offsets` call here: Int64 offsets are
            # exactly the layout that has no 2 GiB ceiling to check.
            if not col_ref._offsets:
                raise Error(
                    "_gather_batch: variable-length column missing offsets"
                    " buffer (arrow_type=" + String(at) + ")"
                )
            comptime int64_size = size_of[Int64]()
            var src_offsets_view = col_ref._offsets.value().view_ro()

            # First pass: total payload bytes the selected rows need.
            var total_data_bytes = 0
            for i in range(count):
                var row = col_ref._offset + (idx_ptr + i)[]
                var start = Int(src_offsets_view.get_typed[Int64](row))
                var end = Int(src_offsets_view.get_typed[Int64](row + 1))
                total_data_bytes += end - start

            var new_offsets = OwnedAlignedBuffer((count + 1) * int64_size)
            var new_data = OwnedAlignedBuffer(max(total_data_bytes, 1))

            # Second pass: copy the payload and rebuild the offsets.
            var dst_offset = 0
            new_offsets.set_length(Int64((count + 1) * int64_size))
            new_offsets.set_typed[Int64](0, Int64(0))
            for i in range(count):
                var row = col_ref._offset + (idx_ptr + i)[]
                var start = Int(src_offsets_view.get_typed[Int64](row))
                var end = Int(src_offsets_view.get_typed[Int64](row + 1))
                var str_len = end - start
                if str_len > 0:
                    new_data.view_range_mut(
                        dst_offset, str_len
                    ).copy_from_view_at(
                        0, col_ref._data.view_range_ro(start, str_len)
                    )
                dst_offset += str_len
                new_offsets.set_typed[Int64](i + 1, Int64(dst_offset))

            new_data.set_length(Int64(total_data_bytes))
            _ = src_offsets_view

            var new_col = Column[HeapRegion](
                arrow_type=at,
                data=new_data^,
                offsets=new_offsets^,
                validity=validity^,
                length=count,
                null_count=null_count,
                offset=0,
            )
            builder.add_column(new_col^)
        elif at == ArrowType.BOOL:
            # ELEMENT-SIZE WIDTH GUARD. BOOL IS BIT-PACKED and must not fall into
            # the fixed-width `else` below, where a byte width is asked of a
            # buffer holding `(count + 7) >> 3` bytes (the width oracle refuses,
            # so SORT or FILTER over a table carrying a bool column would
            # raise).
            #
            # A gather is an INDEXED pick, so `copy_bits_aligned_buffer` (the
            # primitive `_copy_column`'s BOOL arm uses) does not apply — that
            # one moves a contiguous run. `gather_bits_aligned_buffer` is its
            # indexed sibling and lives beside it for the same reason: the
            # bit arithmetic must have ONE definition.
            #
            # NO parallel branch, matching the LARGE_STRING arm above: the
            # parallel helpers are typed for byte-width scatters. A throughput
            # choice, never a correctness one.
            var bm_bytes = (count + 7) >> 3
            var bool_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
            bool_buf.zero()
            gather_bits_aligned_buffer(
                bool_buf, col_ref._data, col_ref._offset, indices
            )
            bool_buf.set_length(Int64(bm_bytes))

            var new_col = Column[HeapRegion](
                arrow_type=ArrowType.BOOL,
                data=bool_buf^,
                offsets=None,
                validity=validity^,
                length=count,
                null_count=null_count,
                offset=0,
            )
            builder.add_column(new_col^)
        else:
            # Fixed-width column: copy elem_size bytes per row.
            # Use typed pointer stores for 8-byte and 4-byte types
            # to avoid memcpy function call overhead per element.
            # Software prefetch hides L2 miss latency on random-access
            # gather patterns (filter indices, join probe indices).
            #
            # The 8B/4B direct-store hot paths use raw typed pointers
            # because `prefetch[](...)` requires a typed
            # `UnsafePointer[Scalar[DType.int64]]` argument — there is no
            # view-based prefetch primitive. Using views would either drop
            # the prefetch or introduce per-iter `view_mut/view_ro` calls.
            var elem_size = element_size(at)
            comptime _GATHER_PF: Int = 16

            var data_buf = OwnedAlignedBuffer(max(count * elem_size, 1))
            if gather_parallel:
                # Parallel indexed scatter as ONE `run_with_state` wave on the
                # engine runtime (cross-thread safety: source RO, output pre-sized +
                # MOVED onto the dispatch State; no Arc/StringArray on a
                # worker). Byte-identical to the serial branches below.
                data_buf = _parallel_fixedwidth_gather[has_pool, D, disp_o](
                    col_ref,
                    indices,
                    count,
                    elem_size,
                    data_buf^,
                    gather_nw,
                    dispatcher_ptr,
                )
            elif elem_size == 8:
                # PERF-CRITICAL: hot path INT64/UINT64/FLOAT64 — direct
                # 8-byte stores with prefetch. Origin-tied chain; ByteView
                # locals pin
                # MmapAlignedBuffer refs alive across the gather loop.
                # @always_inline preserves codegen.
                var dst8_view = data_buf.view_mut()
                var dst8 = dst8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
                var src8_view = col_ref._data.view_ro()
                var src8 = src8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
                var off = col_ref._offset
                for i in range(count):
                    if i + _GATHER_PF < count:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (src8 + off + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                        )
                    (dst8 + i)[] = (src8 + off + (idx_ptr + i)[])[]
            elif elem_size == 4:
                # PERF-CRITICAL: hot path INT32/UINT32/FLOAT32 — direct
                # 4-byte stores with prefetch. Origin-tied chain.
                var dst4_view = data_buf.view_mut()
                var dst4 = dst4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                var src4_view = col_ref._data.view_ro()
                var src4 = src4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
                var off = col_ref._offset
                for i in range(count):
                    if i + _GATHER_PF < count:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (src4 + off + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                        )
                    (dst4 + i)[] = (src4 + off + (idx_ptr + i)[])[]
            elif elem_size == 2:
                # Widths 2 and 1 get typed arms: in the per-row `memcpy`
                # below a SMALLINT payload would be slower than the BIGINT
                # one it strictly undercuts in useful bytes.
                var dst2_view = data_buf.view_mut()
                var dst2 = dst2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
                var src2_view = col_ref._data.view_ro()
                var src2 = src2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
                var off2 = col_ref._offset
                gather_note_narrow_typed(count)
                for i in range(count):
                    if i + _GATHER_PF < count:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (src2 + off2 + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                        )
                    (dst2 + i)[] = (src2 + off2 + (idx_ptr + i)[])[]
            elif elem_size == 1:
                var dst1_view = data_buf.view_mut()
                var dst1 = dst1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
                var src1_view = col_ref._data.view_ro()
                var src1 = src1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
                var off1 = col_ref._offset
                gather_note_narrow_typed(count)
                for i in range(count):
                    if i + _GATHER_PF < count:
                        prefetch[params = PrefetchOptions().for_read().high_locality()](
                            (src1 + off1 + (idx_ptr + i + _GATHER_PF)[]).bitcast[Scalar[DType.int64]]()
                        )
                    (dst1 + i)[] = (src1 + off1 + (idx_ptr + i)[])[]
            else:
                # Per-row view_range_mut + copy_from_view_at (memcpy under
                # the hood).
                # ⛔ IT SURVIVES AND MUST -- see the parallel arm above.
                gather_note_width_fallback(count, elem_size)
                for i in range(count):
                    var src_offset = (col_ref._offset + (idx_ptr + i)[]) * elem_size
                    var dst_offset = i * elem_size
                    data_buf.view_range_mut(
                        dst_offset, elem_size
                    ).copy_from_view_at(
                        0,
                        col_ref._data.view_range_ro(src_offset, elem_size),
                    )
            data_buf.set_length(Int64(count * elem_size))


            var new_col = Column[HeapRegion](
                arrow_type=at,
                data=data_buf^,
                offsets=None,
                validity=validity^,
                length=count,
                null_count=null_count,
                offset=0,
            )
            # DECIMAL128-CORRECTNESS: preserve precision/scale metadata through
            # the fixed-width gather (filter-select / sort / join). The 7-arg
            # Column ctor above sets arrow_type=DECIMAL128 but leaves
            # `_decimal_p`/`_decimal_s` at 0 — so a downstream `as_decimal128()`
            # raises "column carries no precision/scale metadata". Mirror the
            # `copy_column` DECIMAL128-CORRECTNESS arm: prefer the source
            # column's own (p,s); fall back to the batch schema Field if the
            # column wasn't built via Column.from_decimal128. DECIMAL256 carries
            # the same (p,s) and must be propagated identically. (The schema
            # Field metadata is already preserved via `sb.add_field(field_at(c))`
            # above; this closes the COLUMN-level metadata drop.)
            if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
                if col_ref._decimal_p > 0:
                    new_col._decimal_p = col_ref._decimal_p
                    new_col._decimal_s = col_ref._decimal_s
                else:
                    new_col._decimal_p = batch.schema.field_decimal_precision(c)
                    new_col._decimal_s = batch.schema.field_decimal_scale(c)
            builder.add_column(new_col^)

    var schema = sb.build()
    return builder.build(schema^)


def gather_batch_by_sort_indices(batch: RecordBatch, sort_idx: PrimitiveArray[DType.int32]) raises -> RecordBatch:
    """Gather all columns of a RecordBatch using sort permutation indices."""
    var n = sort_idx.length
    _ = batch.num_columns()  # validate batch is not empty
    # Origin-tied chain; `sort_view` ByteView local pins sort_idx alive across the index
    # extraction loop.
    var sort_view = sort_idx.view_ro()
    var sort_ptr = sort_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    # Convert sort indices to List[Int] for _gather_batch. Pre-size to `n` so
    # the index copy is one allocation + n stores (no per-append reallocation /
    # bounds growth) — measurable on 30M-element sort permutations.
    var indices = List[Int](capacity=n)
    for i in range(n):
        indices.append(Int(sort_ptr.load[width=1](i)))
    _ = sort_view

    return gather_batch(batch, indices)


# =============================================================================
# Type conversion helpers
# =============================================================================
#
# ★ THE TWO VALIDITY SEAMS BELOW ARE OFFSET-AWARE.
#
# A sliced operand's validity bitmap must be read from the operand's OWN
# offset and for the WINDOW length, because its data plane is rebased to row 0
# by `as_primitive` / `view_ro`. Reading from bit 0 and taking the WHOLE
# bitmap misaligns the two planes by exactly `offset` bits, and the result
# carries more validity bits than it has rows -- inventing nulls that sit
# before the window and losing nulls inside it (a null that is counted but
# cannot be found, so `is_null` and popcount consumers disagree). The
# comparison seam (`comparison_kleene.merge_cmp_validity`) follows the same
# rule.
#
# THE MECHANISM IS THE OFFSET THREADED INTO `Bitmap.copy_slice_from`, called
# with the operand's own offset and the WINDOW length instead of
# `(0, bm.length)`. At `offset == 0` with `bm.length == length` it is the plain
# byte-aligned memcpy.
#
# ⚠ WHAT THIS DOES **NOT** COVER. The per-row `X.validity.value().test(i)`
# walks in the join / binary-fn operators are reachable only through a column
# that HAS a validity bitmap, which the zero-copy share gates
# (`column.mojo`'s `can_share_as_primitive`) refuse. They are safe BECAUSE of
# those gates, so this is NOT licence to widen them, nor to let the morsel
# splitter zero-copy a nullable column.
# =============================================================================


def _install_validity_window[
    dtype: DType
](mut result: PrimitiveArray[dtype], var window: Bitmap[HeapRegion]) raises:
    """Give `result` the validity `window`, MERGING when the KERNEL has already
    established one of its own. THE ONE definition of that rule.

    ★ WHY THIS EXISTS AS A SHARED HELPER. `clone_array_validity` and
    `merge_binary_arith_validity` are two copies of the same seam: compute
    the operands' validity window, put it on a freshly allocated kernel
    result. Written as an ASSIGNMENT, each is correct exactly as long as no
    kernel establishes validity of its own. `eval_div` / `eval_div_scalar` do
    — an integral divide-by-zero marks that row NULL — and an assignment
    would throw that mask away one line after the kernel produced it: the row
    would come back VALID holding the allocated 0, i.e. `x / 0 == 0`, with no
    raise and no warning. A fix made in only one of two copies leaves the
    other route broken, so the rule has ONE home and both seams call it.

    THE RULE: **a result row is valid iff the operand window says valid AND the
    kernel did not invalidate it.** A kernel may only ever take validity away,
    never grant it, so AND is the whole rule — and it is the rule that was
    true whether or not the kernel has an opinion.

    OFFSET-AWARE via `result.offset`, matching the window semantics documented
    in the block above: `window` is already rebased to the result's row 0 by
    `Bitmap.copy_slice_from`, while `result`'s own bitmap is indexed
    absolutely."""
    if not result.validity:
        result.null_count = window.null_count()
        result.validity = window^
        return
    ref bm = result.validity.value()
    var n = result.length
    var nulls = 0
    for i in range(n):
        if not window.test(i):
            bm.clear(result.offset + i)
        if not bm.test(result.offset + i):
            nulls += 1
    result.null_count = nulls


def merge_binary_arith_validity[
    dtype: DType
](left: Column[HeapRegion], right: Column[HeapRegion], mut result: PrimitiveArray[dtype]) raises:
    """Set `result`'s validity to AND(left.validity, right.validity) and
    recompute `result.null_count`.

    Nullable arithmetic (`a + b`, `a - b`, `a * b`, `a / b`) produces a
    NULL output wherever either input is NULL (Arrow/DuckDB/SQL). The
    SIMD compute path leaves the NULL data slots as whatever the
    operation produced (typically zero); the validity bitmap is what
    makes those slots logically NULL. Without this merge a nullable
    arithmetic result comes back claiming all-valid (silent-wrong bug).

    Fast paths:
      * both inputs non-null → result stays non-null (no allocation).
      * only one input has validity → clone that one's WINDOW.
      * both have validity → rebase each window, then bitmap-AND them.

    OFFSET-AWARE. A `Column` may be an Arrow SLICE:
    logical row `i` is ABSOLUTE row `_offset + i` in BOTH planes, and
    `Column.slice` SHARES the whole-column validity bitmap rather than rebasing
    it. The arithmetic kernels read their values through `as_primitive` /
    `view_ro`, which REBASE the data to row 0 — so reading validity from bit 0
    misaligns the two planes by exactly `_offset` bits, and the window's own
    bit length is `result.length`, not `bm.length`. See the block above
    `clone_array_validity`.
    """
    if not left._validity and not right._validity:
        # Neither operand constrains validity, so whatever the KERNEL put on
        # `result` is the whole answer and must be left alone. This early
        # return keeps a divide-by-zero mask over two null-FREE columns.
        return
    var n = result.length
    if left._validity and not right._validity:
        var cloned = Bitmap.copy_slice_from(
            left._validity.value(), left._offset, n
        )
        _install_validity_window[dtype](result, cloned^)
        return
    if right._validity and not left._validity:
        var cloned = Bitmap.copy_slice_from(
            right._validity.value(), right._offset, n
        )
        _install_validity_window[dtype](result, cloned^)
        return
    # Both have validity — rebase each operand's WINDOW to bit 0, then AND.
    # `bitmap_and` is itself offset-blind (it walks both inputs from bit 0), so
    # the rebase is what makes it correct here rather than a second AND kernel:
    # ONE mechanism, with the offset threaded into the primitive both arms
    # use. At `_offset == 0` with `bm.length == n` each rebase is
    # `copy_slice_from`'s byte-aligned memcpy.
    var lw = Bitmap.copy_slice_from(left._validity.value(), left._offset, n)
    var rw = Bitmap.copy_slice_from(right._validity.value(), right._offset, n)
    var merged = bitmap_and(lw, rw)
    _install_validity_window[dtype](result, merged^)


def clone_array_validity[
    from_dtype: DType, to_dtype: DType
](src: PrimitiveArray[from_dtype], mut dst: PrimitiveArray[to_dtype]) raises:
    """Copy `src`'s validity bitmap (if any) onto `dst` and recompute null_count.

    Casts must preserve the input validity on the output (Arrow/DuckDB
    semantics — `cast(nullable_col AS ...)` keeps the null mask). Without
    this, a nullable cast comes back claiming all-valid (silent-wrong bug).
    No-op if `src` has no validity bitmap. `dst` is a freshly-allocated,
    REBASED array (`offset == 0`) of `src.length` rows.
    Pure value semantics, no raw pointers escape.

    OFFSET-AWARE — see the block above. `src` may be an Arrow SLICE, in which case logical row `i`
    is ABSOLUTE row `src.offset + i` of both planes, and the window is
    `src.length` bits, NOT `src_bm.length`.

    ★ IT MERGES, IT DOES NOT OVERWRITE. An unconditional
    `dst.validity = cloned` is correct only as long as `dst` is a
    freshly-allocated array with no validity — i.e. as long as no KERNEL
    establishes validity of its own. `eval_div` / `eval_div_scalar` do: an
    integral divide-by-zero marks that row NULL, and an overwrite at the call
    site would throw that mask away and hand back a column claiming to be
    valid everywhere, with no diagnostic.

    The merge rule is the one that is true in general and was only ever
    trivially true before: **a result row is valid iff the input row was valid
    AND the kernel did not invalidate it.** A kernel may only ever take
    validity away, never grant it, so AND is the whole rule.

    A `dst` straight out of `PrimitiveArray.allocate()` has `validity ==
    None`, and the `if not dst.validity` arm below is then a plain
    assignment. Only a kernel that opted in by allocating nullable reaches
    the merge arm. `test_preexisting_null_survives_div_by_zero_guard`
    and `test_preexisting_null_survives_nonzero_div` assert both directions.
    """
    if not src.validity:
        return
    ref src_bm = src.validity.value()
    var cloned = Bitmap.copy_slice_from(src_bm, src.offset, src.length)
    # ONE definition of the merge rule, shared with
    # `merge_binary_arith_validity` — see `_install_validity_window`. Two
    # independent copies of the rule drift apart; sharing the definition keeps
    # the col/SCALAR and col/COLUMN arithmetic routes in agreement.
    _install_validity_window[to_dtype](dst, cloned^)


@always_inline
def int64_to_float64(arr: PrimitiveArray[DType.int64]) raises -> PrimitiveArray[DType.float64]:
    """Convert an Int64 array to Float64 (validity-preserving)."""
    var result = PrimitiveArray[DType.float64].allocate(arr.length)
    # Origin-tied chain; `src_view`/`dst_view` ByteView
    # locals pin both arrays alive across the conversion loop.
    var src_view = arr.view_ro()
    var src_ptr = src_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var dst_view = result.view_mut()
    var dst_ptr = dst_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    for i in range(arr.length):
        dst_ptr.store[width=1](i, Scalar[DType.float64](Float64(Int(src_ptr.load[width=1](i)))))
    clone_array_validity[DType.int64, DType.float64](arr, result)
    return result^


@always_inline
def float64_to_int64(arr: PrimitiveArray[DType.float64]) raises -> PrimitiveArray[DType.int64]:
    """Convert a Float64 array to Int64, TRUNCATING TOWARD ZERO (validity-preserving).

    ⛔⛔ THIS IS **NOT** THE SQL `CAST(<float> AS <integer>)` RULE. SQL rounds
    HALF TO EVEN (`CAST(2.5::DOUBLE AS BIGINT)` is 2, `3.5` is 4, `-1.5` is
    -2); `Int(x)` below truncates (`-1.5` -> `-1`). The cast rule has ONE
    spelling and it is `komira_core.eval.cast_null.eval_cast_float_to_int`.

    ⚠ The EXPR_CAST arm in `compiler_eval_column` uses the rounding kernel,
    not this. This cannot simply DELEGATE to that kernel: `komira_core/eval/*` already
    imports THIS module (`numeric_unary` takes `clone_array_validity` from it), so
    an import the other way is a cycle. If you need a float->integer conversion,
    take the one in `cast_null`; if you genuinely need truncation, say so at the
    call site, because the next reader will assume this is the cast.
    """
    var result = PrimitiveArray[DType.int64].allocate(arr.length)
    # Origin-tied chain.
    var src_view = arr.view_ro()
    var src_ptr = src_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    var dst_view = result.view_mut()
    var dst_ptr = dst_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    for i in range(arr.length):
        dst_ptr.store[width=1](i, Scalar[DType.int64](Int(src_ptr.load[width=1](i))))
    clone_array_validity[DType.float64, DType.int64](arr, result)
    return result^


def broadcast_scalar(
    sv: ScalarValue, num_rows: Int
) raises -> Column[HeapRegion]:
    """Broadcast a scalar value into a Column[HeapRegion] of the given length."""
    if sv.is_null():
        # Broadcast a typed NULL literal: a nullable column of the null's logical
        # type (`null_type()`) with EVERY row null. Used for a CASE with an omitted
        # ELSE (SQL default NULL, e.g. `CASE WHEN v >= 30 THEN v END`) and any other
        # null-literal projection. Without this arm a null ScalarValue (whose
        # `dtype` is the `DTYPE_NONE` null discriminant) fell through to the
        # "default zero int64" tail below, SILENTLY producing valid 0s instead of
        # NULLs.
        if sv.null_type() == DType.float64:
            var arr_f = PrimitiveArray[DType.float64].allocate_nullable(num_rows)
            for i in range(num_rows):
                arr_f.validity.value().clear(i)
            arr_f.null_count = num_rows
            return Column.from_primitive[DType.float64](arr_f)
        var arr_i = PrimitiveArray[DType.int64].allocate_nullable(num_rows)
        for i in range(num_rows):
            arr_i.validity.value().clear(i)
        arr_i.null_count = num_rows
        return Column.from_primitive[DType.int64](arr_i)
    if sv.is_date32():
        # ★★ THE DATE32 ARM. `ScalarValue.date32()` is `_kind`-tagged
        # (`SCALAR_KIND_DATE32`) and leaves `dtype` at `DTYPE_NONE`, so every
        # `sv.dtype == ...` test below misses it; without this arm a DATE
        # literal falls to the tail arm (`# Default: create a zero int64
        # column`) and `SELECT DATE '2030-01-08'` returns INT64 ZEROS.
        #
        # ⛔ AND ZERO IS A VALID DAY NUMBER — 1970-01-01. The wrong answer
        # would not be a crash and not a sentinel, it would be a real date,
        # the same one for every literal in existence.
        #
        # ⚠ THE `_kind` TEST, NOT A `dtype` TEST, AND THE MIRROR MUST COPY IT
        # THAT WAY. `plan_wire_values._literal_is_materializable` is a
        # line-for-line mirror of this ladder, with the same `is_date32()` arm
        # in the same position.
        #
        # ⚠ NON-NULLABLE, like every other non-null arm here, matching
        # `walk_expr_field`'s `Field("literal", at, False)` — a literal is
        # never null, so a validity bitmap would be a buffer nothing reads.
        #
        # ⚠ RELABEL RATHER THAN `from_primitive_with_arrow_type`: that helper
        # COPIES the whole buffer to stamp a tag. A DATE32 is physically an
        # int32, so the tag is the only thing that differs — the same
        # relabel-in-place `compiler_eval_column`'s EXPR_CAST temporal arms do.
        var arr_d = PrimitiveArray[DType.int32].allocate(num_rows)
        var d_view = arr_d.view_mut()
        var d_ptr = d_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var d_val = Scalar[DType.int32](Int32(Int(sv.date32_val)))
        for i in range(num_rows):
            d_ptr.store[width=1](i, d_val)
        var d_col = Column.from_primitive[DType.int32](arr_d)
        d_col.arrow_type = ArrowType.DATE32
        return d_col^
    if sv.is_timestamp():
        # ★★ THE TIMESTAMP ARM — the same `_kind`-tagged shape. It is not
        # reachable from SQL text (the SQL parser has no TIMESTAMP literal),
        # but it is reachable through a plan carrying
        # `Expr.literal(ScalarValue.timestamp_micros(...))`.
        #
        # ⚠ TIMESTAMP_US AND NOT SOME OTHER UNIT: `ScalarValue` stores ONE
        # timestamp member, `ts_micros`, and its factory is
        # `timestamp_micros`. There is no unit to choose and choosing one from
        # `time_unit` (which discriminates the TIME family, not this one)
        # would be reading a member this kind does not set.
        var arr_t = PrimitiveArray[DType.int64].allocate(num_rows)
        var t_view = arr_t.view_mut()
        var t_ptr = t_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var t_val = Scalar[DType.int64](Int64(Int(sv.ts_micros)))
        for i in range(num_rows):
            t_ptr.store[width=1](i, t_val)
        var t_col = Column.from_primitive[DType.int64](arr_t)
        t_col.arrow_type = ArrowType.TIMESTAMP_US
        return t_col^
    if sv.is_decimal128():
        # ★★ THE DECIMAL128 ARM — the same `_kind`-tagged shape as DATE32. A
        # DECIMAL `ScalarValue` leaves `dtype` at its default, so without this
        # arm `SELECT k, CAST(12345 AS DECIMAL(18,0)) FROM T` would answer 0 on
        # every row, stamped as decimal zeros -- silently. The value is the exact
        # unscaled int128 and the (p, s) the literal carries; a literal is never
        # null, so no validity bitmap. `plan_wire_values._literal_is_
        # materializable` mirrors this arm in the same position.
        var darr = Decimal128Array.allocate(
            num_rows,
            sv.dec128_precision if sv.dec128_precision > 0 else 38,
            sv.dec128_scale,
        )
        var dval = sv.decimal_value_i128()
        for i in range(num_rows):
            darr.set_i128(i, dval)
        return Column.from_decimal128(darr)
    if sv.dtype == DType.int64:
        var arr = PrimitiveArray[DType.int64].allocate(num_rows)
        # Origin-tied chain; `arr_view` ByteView local pins the fresh-allocated arr alive
        # across the broadcast loop until `arr^` moves into Column.from_primitive.
        var arr_view = arr.view_mut()
        var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        var val = Scalar[DType.int64](sv.int_val)
        for i in range(num_rows):
            ptr.store[width=1](i, val)
        return Column.from_primitive[DType.int64](arr)
    elif sv.dtype == DType.float64:
        var arr = PrimitiveArray[DType.float64].allocate(num_rows)
        # Origin-tied chain: see int64 arm above.
        var arr_view = arr.view_mut()
        var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
        var val = Scalar[DType.float64](sv.float_val)
        for i in range(num_rows):
            ptr.store[width=1](i, val)
        return Column.from_primitive[DType.float64](arr)
    elif sv.dtype == DType.int32:
        var arr = PrimitiveArray[DType.int32].allocate(num_rows)
        # Origin-tied chain: see int64 arm above.
        var arr_view = arr.view_mut()
        var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        var val = Scalar[DType.int32](Int32(Int(sv.int_val)))
        for i in range(num_rows):
            ptr.store[width=1](i, val)
        return Column.from_primitive[DType.int32](arr)
    elif sv.dtype == DType.float32:
        var arr = PrimitiveArray[DType.float32].allocate(num_rows)
        # Origin-tied chain: see int64 arm above.
        var arr_view = arr.view_mut()
        var ptr = arr_view._unsafe_ptr().bitcast[Scalar[DType.float32]]()
        var val = Scalar[DType.float32](Float32(sv.float_val))
        for i in range(num_rows):
            ptr.store[width=1](i, val)
        return Column.from_primitive[DType.float32](arr)
    elif sv.dtype == DType.bool:
        # ★ THE BOOL ARM. Without it a bool literal falls to the `else` tail
        # below and becomes a column of INT64 ZEROS, so `SELECT TRUE AS b`
        # produces a batch whose Column says int64 while the plan's own schema
        # says BOOL (`RecordBatch.column_arrow_type: PHYSICAL LAYOUT
        # CONFLICT`), and TRUE and FALSE produce the IDENTICAL batch.
        #
        # ⚠ BOOL IS BIT-PACKED, WHICH IS WHY THIS IS NOT A `PrimitiveArray`
        # ARM. Arrow stores a boolean as one BIT, `(n+7)>>3` bytes for n rows;
        # every arm above is a fixed-BYTE-width store. Writing bools through
        # `PrimitiveArray[DType.bool]` + a `Scalar` store is an 8x
        # over-write.
        # `BooleanArray.set` goes through `Bitmap`, which is the one writer
        # that knows the layout.
        #
        # ⚠ NON-NULLABLE, LIKE EVERY OTHER NON-NULL ARM HERE, and this MATCHES
        # `walk_expr_field`'s `Field("literal", at, False)` — a literal is
        # never null, so a validity bitmap would be a buffer nothing reads.
        var barr = BooleanArray.allocate(num_rows)
        if sv.bool_val:
            for i in range(num_rows):
                barr.set(i, True)
        return Column.from_boolean(barr)
    elif sv.is_string():
        # String literal broadcast. ScalarValue uses `dtype == DTYPE_NONE` +
        # non-empty `string_val` for Utf8 literals (see scalar_value.mojo
        # `is_string`). Without this arm, `lit("foo")` would fall through to
        # the int64 default, producing an INT64 column instead of STRING.
        var values = List[String](capacity=num_rows)
        for _ in range(num_rows):
            values.append(sv.string_val.copy())
        return Column.from_string(StringArray.from_strings(values))
    else:
        # Default: create a zero int64 column
        var arr = PrimitiveArray[DType.int64].allocate(num_rows)
        return Column.from_primitive[DType.int64](arr)


# =============================================================================
# element_size — THE FIXED-BYTE-WIDTH TABLE.  IT DOES NOT GUESS.
# =============================================================================
#
# ⛔ THERE IS NO `else: return 8` ANY MORE, AND ADDING ONE BACK IS THE DEFECT.
#
# The ladder, and the layouts a lenient default silently mis-sizes
# (INTERVAL_MONTH_DAY_NANO, DECIMAL256, LARGE_STRING, and the
# DATE32/TIME32_*/INTERVAL_YEAR_MONTH family), are documented at the ONE
# definition: `komira_core/arrow/arrow_types.mojo:arrow_fixed_byte_width`.
#
# ⚠ DO NOT RE-INLINE THE LADDER HERE. A second copy drifts from the first,
#   and a fix lands in one copy but not the other.
# =============================================================================


@always_inline
def element_size(arrow_type: ArrowType) raises -> Int:
    """Return the byte width of a FIXED-BYTE-WIDTH ArrowType.

    Args:
        arrow_type: The ArrowType to measure.

    Returns:
        Bytes per element, for types that have a fixed per-element byte width.

    Raises:
        Error naming `arrow_type` if it has NO fixed byte width — bit-packed
        (BOOL), offsets-carrying (STRING / BINARY / LARGE_*), width-in-schema
        (FIXED_SIZE_BINARY), nested (LIST / STRUCT / MAP / UNION_* /
        FIXED_SIZE_LIST / LARGE_LIST), view (UTF8_VIEW / BINARY_VIEW /
        LIST_VIEW / LARGE_LIST_VIEW), dictionary-encoded, NULL, or ERROR.
        Callers that reach this raise are doing `n * width` byte arithmetic on
        a layout that has no `width`; the fix is at the caller, not here.
    """
    # ONE DEFINITION, TREE-WIDE. The ladder itself lives in the LEAF module
    # `arrow/arrow_types.mojo` so the copies inside `komira_core/arrow/`
    # can share it too (an `arrow/* -> helpers/*` import closes a
    # package-init cycle). This name is kept because call sites in several
    # packages import `element_size` from here.
    return arrow_fixed_byte_width(arrow_type)


# ⚠ CALLERS THAT DO `n * element_size(at)` BYTE ARITHMETIC, AND WHAT A RAISE
# MEANS FOR THEM. The copy / gather / slice / join-output helpers
# (`_copy_column`, `gather_batch_dispatch`, `compiler_join_assembly`,
# `compiler_join_fused`, `compiler_join_chunked`, `arrow_helpers/batch_slice`)
# and several engine-operator and dispatch sites do this. For
# DATE32 / TIME32_S / TIME32_MS / INTERVAL_YEAR_MONTH the table gives the right
# width. For the layouts that RAISE, these arms never had a correct answer, and
# the places that genuinely needed one have their own arm:
#
#   * BOOL — its buffer is `(n + 7) >> 3` bytes, so NO per-row byte width is
#     right; a width of 8 would be a 64x overread that happens to look right
#     only while `_offset == 0`. `_copy_column` and the scan source have an
#     explicit bit-packed arm using `copy_bits_aligned_buffer` (the primitive
#     `arrow/copy_column_ref.mojo` uses too), so BOOL flows through
#     `copy_batch` correctly rather than raising.
#   * STRING / BINARY / LARGE_* / DICTIONARY / nested — `_copy_column`,
#     `gather_batch_dispatch` and `batch_slice` branch on these BEFORE the
#     fixed-width arm, so the raise is unreachable from them. Where a site
#     has no varlen branch, raising, naming the type, is strictly better than
#     building a malformed Column (a STRING column's OFFSETS copied into a
#     Column with `offsets=None`). `compiler_join_fused` / `_chunked` are
#     gated upstream by `_is_variable_length_type` /
#     `_any_schema_has_var_len`.


# =============================================================================
# Selection-mask materialize (defensive safety net)
# =============================================================================
#
# When `_decode_with_late_mat` short-circuits the gather at >=95% selectivity
# (the late-materialization lever), the returned RecordBatch carries a
# `_selection_mask` BooleanArray and the FULL column payload — no rows have
# been physically dropped. Consumers MUST honor the mask in one of two ways:
#
#   (a) Native — rewrite the per-row loop to read `mask.test(row)` and skip
#       rejected rows. Cheaper for hot paths (one extra branch per row,
#       well-predicted at >=95% selectivity). Used by the agg consume.
#
#   (b) Defensive — call `materialize_selection_if_present(batch)` at entry,
#       which performs the gather, returning a smaller batch with the mask
#       cleared. This MOVES the gather cost from late-mat to the consumer
#       site, so it does not deliver the wall savings — it is the
#       correctness fallback for consumers that do not honor masks.
#
# Every consumer of `RecordBatch` must do (a) or (b); skipping both
# over-aggregates by the rejected fraction.


def materialize_selection_if_present(var batch: RecordBatch) raises -> RecordBatch:
    """If `batch` carries a `_selection_mask`, perform `gather_batch` to
    drop the rejected rows and return a smaller mask-cleared batch.
    Otherwise return the batch unchanged.

    Defensive safety net for consumers that do not natively honor the
    selection mask. See the module-level selection-mask comment.
    """
    if not batch.has_selection_mask():
        return batch^
    var mask_opt = batch.take_selection_mask()
    var mask = mask_opt.take()
    var total = batch.num_rows()
    var surviving = mask.true_count()
    if surviving == total:
        # All bits set: mask is degenerate, batch is already complete.
        return batch^
    if surviving == 0:
        # All rejected: build an empty batch with same schema.
        return empty_batch_like(batch)
    var indices = filter_to_indices(mask)
    return gather_batch(batch, indices)
