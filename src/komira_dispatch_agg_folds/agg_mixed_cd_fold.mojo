# =============================================================================
# agg_mixed_cd_fold.mojo — the MIXED COUNT(DISTINCT) + FIXED-CELL grouped/scalar
#   serial fold.
# =============================================================================
#
# ★ THE GAP THIS CLOSES, EXACTLY. `agg_node_exec._run_agg_over_batch` — the
# resident-batch agg kernel every breaker-child / in-mem / demoted-row-scan
# aggregate lands on — has THREE other arms and an ordinary SQL query matches
# NONE of them:
#
#     SELECT k, COUNT(DISTINCT x), AVG(y) FROM t GROUP BY k
#
#   1. the ALL-COUNT_DISTINCT arm (`cd_grouped_fold.agg_all_count_distinct`)
#      requires EVERY agg in the node to be a CD;
#   2. the EXTENDED arm (`agg_extended_grouped.extended_agg_servable`) covers
#      MEDIAN / LARGEST_K / CORR and REFUSES a CD outright
#      (`_agg_base_supported(AGG_COUNT_DISTINCT)` is False);
#   3. the fixed-cell fall-through (`_build_agg_descriptors_for_schema` ->
#      `HashAggUntypedSink`) DECLINES CD because — in that arm's own words — "a
#      distinct SET is not an AggSpec cell".
#
# So without this arm a node MIXING a CD with a fixed-cell aggregate falls
# between all three and RAISES. `materialize_subplan._plan_is_all_count_distinct`
# states the same fact from the routing side: a mixed `count(distinct x),
# sum(y)` aggregate is NOT all-CD, so it routes to the plain agg exec.
#
# ⚠ THE DECLINE IN ARM 3 IS LOAD-BEARING AND IS NOT RELAXED HERE. The flat cell
# kernel's per-group state is a FIXED-WIDTH byte cell inside one row of a packed
# slab (`AggSpec.state_byte_width` — 8 for SUM/COUNT/MIN/MAX, 16 for AVG, 24 for
# the Welford stats). A per-group DISTINCT SET is unbounded and heap-owning; it
# cannot live in that slab, and the parallel COMBINE that makes the kernel fast
# would have to union sets across workers. That is why the CD folds are separate
# arms, and why this is a FOURTH ARM rather than a widening of the cell kernel.
#
# WHY A FOURTH ARM AND NOT A WIDENING OF ARM 1 OR ARM 2 — measured against the
# code, not against tidiness:
#   * Arm 1 (`fold_grouped_count_distinct_over_batch`) owns the right
#     GROUP-KEY machinery (native-hash over STRING / INT32 / INT64, composite
#     keys) but has no fixed-cell accumulator at all, and its emit is "n_keys key
#     cols + n_aggs INT64 counts" — an emit shape that cannot express a FLOAT64
#     AVG column. Teaching it both would roughly double the size of that file
#     AND put the byte-equiv oracle (`_fold_grouped_cd_stringkey`, pinned by
#     `tests/test_cd_grouped_fold.mojo`) at risk on every future edit.
#   * Arm 2 (`agg_extended_grouped`) IS a mixed variable-state + base
#     accumulator engine (MEDIAN's per-group value buffer sits beside a SUM
#     cell), so it looks like the natural host — but it serves INT64 keys only
#     and it pre-widens EVERY agg input to `Float64` (`_ExtColData.vals:
#     List[Float64]`). A CD folded there would count distinct over values
#     rounded to F64, i.e. a SILENT WRONG ANSWER for any INT64 input above 2^53,
#     and it would still refuse `GROUP BY <string>` — which is where mixed CD
#     queries live (`SELECT dept, COUNT(DISTINCT user), SUM(amt) ... GROUP BY
#     dept`).
#   ⇒ This module reuses arm 1's group-key extraction VERBATIM (the same
#     `_CDNativeKeyCol` / `_cd_extract_native_key_col` / `_cd_native_keys_equal`
#     the q16 fold uses — as `fold_grouped_string_minmax_over_batch` does too)
#     and adds fixed-cell accumulators beside the distinct sets. CD values stay
#     EXACT Int64.
#
# THE SHAPE THIS SERVES (anything else DECLINES -> None; the caller raises a
# legible cap error, never a silent wrong answer):
#   * 0..N group-by KEY col_refs, each STRING / INT32 / INT64, with NO NULLS in
#     the key column (see the null-key note below). n_keys == 0 is the scalar
#     twin of the same gap (`SELECT COUNT(DISTINCT x), COUNT(*) FROM t`) and is
#     served here too, emitting exactly one row.
#   * >= 1 OFF-CELL agg — a `AGG_COUNT_DISTINCT` over a plain col_ref of an
#     INT32 / INT64 / FLOAT32 / FLOAT64 input, or a MIN/MAX over a plain col_ref
#     of a STRING / LARGE_STRING input (see the string MIN/MAX block below) —
#     AND
#   * >= 1 agg that is neither — each of those `SUM / COUNT / MIN / MAX / MEAN`
#     over a plain col_ref of an int-family / float-family input, or bare
#     `COUNT(*)`.
#   * the resident batch is within the serial-fold scale ceiling. ⭐ THAT
#     CEILING IS THIS FOLD'S OWN, NOT INHERITED from the all-CD fold's
#     `_CD_FOLD_MAX_ROWS` — `mixed_offcell_row_ceiling_for_schema`, the scale
#     ceiling block below.
#     ⚠ IT IS ONE NUMBER, AND THE FUNCTION READS NEITHER OF ITS TWO ARGUMENTS:
#     no term of the ceiling varies by node. The operands are kept in the
#     signature deliberately — see the function's own docstring — but do NOT
#     read this bullet as saying the answer varies by node. It does not.
#
# NOT SERVED, DELIBERATELY (each DECLINES to a legible raise, and each is a
# named follow-on rather than an accident):
#   * a CD mixed with an EXTENDED op (MEDIAN / LARGEST_K / CORR) or with
#     STDDEV_SAMP / VAR_SAMP. Serving those means giving arm 2 an exact-Int64
#     input channel; that is a change to a large parallel fold with its own
#     byte-equivalence oracles and it is not bundled in here.
#   * a NULL-BEARING group-key column. This fold forms no NULL group, and the
#     fixed-cell kernel does form one, so serving a null-key row any other way
#     would make a mixed query's row count depend on which arm served it.
#     Declining is the only answer that cannot be silently wrong; it is checked
#     with `Column.null_count()`, not inferred.
#   * a STRING **CD** input (`COUNT(DISTINCT <varchar>)`) — the distinct key is
#     an Int64 and there is no exact string key channel.
#
# SEMANTICS — matched to the SIBLING SERIAL FOLDS, on purpose:
#   * NULL agg inputs are SKIPPED. A group whose contributing count is 0 emits
#     NULL for SUM / MIN / MAX / MEAN (`agg_scalar_fold`'s "ZERO CONTRIBUTING
#     ROWS -> NULL" rule) and 0 for COUNT / COUNT(DISTINCT).
#   * Output DTypes follow `agg_node_exec._agg_output_arrow`, the fixed-cell
#     kernel's contract: COUNT / COUNT(DISTINCT) / int-family SUM,MIN,MAX ->
#     INT64; MEAN and float-family SUM,MIN,MAX -> FLOAT64; a MIN/MAX over a
#     STRING / LARGE_STRING input -> STRING.
#   * Output NAMES come from `agg_out_field_name` — THE authority, the same one
#     the plan's own `output_schema` uses — so a caller reading the result BY
#     NAME lands on the same string the plan declared.
#   * GROUP KEYS are emitted in their NATIVE Arrow type (an INT32 key stays
#     INT32), matching the fixed-cell kernel's `_build_agg_descriptors_for_schema`
#     emit and the plan's declared output schema. (The all-CD fold WIDENS an
#     INT32 key to INT64; that asymmetry is not propagated into this module.)
#   * COUNT(DISTINCT) over a FLOAT input counts distinct IEEE-754 BIT PATTERNS —
#     the same thing `WorkerCDState.consume_batch` counts (it reads every value
#     column through `bitcast[Scalar[DType.int64]]()`), so the mixed arm and the
#     all-CD sink agree. `-0.0` is normalised to `+0.0` first so the two spellings
#     of zero do not count twice.
#
# =============================================================================
# ⭐ STRING MIN/MAX BESIDE ANOTHER AGGREGATE.
# =============================================================================
#
# `SELECT search_phrase, min(url), count(*) ... GROUP BY search_phrase` is not
# served by the all-MIN/MAX route (`fold_grouped_string_minmax_over_batch`),
# which requires EVERY aggregate in the node to be a MIN/MAX: one `count(*)`
# beside it drops the query onto the fixed-cell descriptor build, which
# declines a STRING agg value. `SELECT search_phrase, min(url) ... GROUP BY
# search_phrase` — the SAME aggregate, alone — is served there. The difference
# is not about strings.
#
# A STRING MIN/MAX is OFF-CELL for exactly the reason a distinct set is — a
# variable-length value has no fixed-width `AggSpec` slab cell — so it belongs
# HERE, beside the sets, rather than in a third fold. `_MIX_KIND_STR` is that
# accumulator: a per-(group, agg) current-best ROW + an any-seen flag, folded
# in the SAME serial pass, over the SAME native-hash group table.
#
# ⚠ AND THE GATE IS SPLIT IN TWO FOR IT. `min(<varchar>)` and `min(<bigint>)`
# are the same plan node; only a SCHEMA tells them apart. See
# `agg_mixed_offcell_candidate` / `mixed_offcell_servable_for_schema` and the
# comment above them — admitting MIN/MAX structurally would route every
# ordinary numeric `min(v), count(*)` off the parallel kernel and into this
# single-threaded fold.
#
# ⭐ THE STRING VALUE COLUMN IS NOT STAGED PER ROW. Copying each input cell into
# an OWNED `String` before folding — one per INPUT ROW per string aggregate (24
# B of struct, no small-string optimisation on Mojo 1.0.0, plus the value's own
# heap allocation), on top of the full buffer COPY `column_as_string` takes
# (`Column.as_string`: "The data is COPIED") — would cost memory in proportion
# to rows, not groups, and would force this arm a row-count ceiling an order of
# magnitude below the other.
#
# The group key column already shows the pattern:
# `_cd_extract_native_key_col` (imported above, and used a few lines into the
# fold) keeps the Arrow `StringArray` itself and reaches each cell through the
# zero-copy `get_span`, retaining one representative ROW per group. The value
# column does the same: the fold adopts the column (Arc-SHARING its buffers
# where `can_share_as_string` allows), compares cells in place with
# `_mix_str_row_is_before`, keeps a per-(group, aggregate) ROW INDEX, and builds
# exactly ONE `String` per group — at emit.
#
# ⇒ a STRING MIN/MAX costs 8 bytes per group and — on a plain STRING column it
# can SHARE — nothing per row, so there is one ceiling for the whole fold.
# ⚠ NOT UNCONDITIONALLY ZERO: a DICTIONARY-encoded or LARGE_STRING input takes
# the dense `column_as_string` decode, which is O(rows). That is the SAME term a
# STRING GROUP KEY pays on every arm, which is why it does not buy the
# string-value arm a ceiling of its own; THE ARITHMETIC below prices both
# halves. ⛔ THE FOLD IS SERIAL. A parallel string min/max is separate work;
# see the value-stability rail below.
# =============================================================================
#
# The fold is SERIAL — one open-address group table, one `Set[Int64]` per
# (group, CD agg), one retained best ROW per (group, string MIN/MAX agg), one
# fixed cell per (group, base agg), a single forward pass in row order.
# Value-stable by construction (no parallel combine, no float
# reassociation), which is the same correctness rail the 0-key scalar fold
# (`agg_scalar_fold`), the extended fold (`agg_extended_fold`) and the q16 CD
# fold all stand on.
#
# Encapsulation (pointer rules): no `UnsafePointer` in any signature here,
# no wildcard origins, no `unsafe_from_address`, no partial-move-out-of-a-field.
# The accumulators are plain `List` / `Set` / POD cells.
# =============================================================================

from std.collections import Optional, Set
from std.collections import List

from komira_arrow.schema import (
    Schema, SchemaBuilder, Field, ArrowType, RecordBatch, RecordBatchBuilder,
)
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_plan_ir.logical_plan_variants import AggregateData
from komira_plan_ir.logical_plan import agg_out_field_name
from komira_plan_expr.agg_expr import (
    AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN, AGG_COUNT_DISTINCT,
)

# The GROUP-KEY half is arm 1's, reused verbatim — the native-hash key columns,
# the composite-key equality, the key-DType envelope, the col_ref stripper and
# the shared serial-fold scale ceiling. `fold_grouped_string_minmax_over_batch`
# (in `cd_grouped_fold`) reuses them from a DIFFERENT accumulator in the same
# way.
from komira_agg_api.cd_distinct_key import (
    cd_distinct_key_channel,
    cd_distinct_keys_for_column,
    cd_null_mask_for_column,
    cd_value_type_supported,
)
from komira_udf.float_quotient_order import (
    float_quotient_gt_f64,
    float_quotient_lt_f64,
)
from komira_dispatch_agg_folds.cd_grouped_fold import (
    _CDNativeKeyCol,
    _cd_extract_native_key_col,
    _cd_native_keys_equal,
    _cd_hash_combine,
    _cd_key_dtype_ok,
    _cd_col_idx,
    _cd_strip_alias_col_ref,
)


# --- Per-agg kind, resolved once at plan time. -------------------------------
comptime _MIX_KIND_CD: UInt8 = 0
comptime _MIX_KIND_BASE: UInt8 = 1
# ★ STRING MIN/MAX — a MIN/MAX whose input column is STRING / LARGE_STRING.
# It is the SECOND off-cell accumulator in this fold, and it is off-cell for the
# SAME reason the distinct set is: a variable-length String best-value cannot
# live in the flat kernel's fixed-width byte slab (`_agg_input_supported(STRING)`
# is False, so the fixed-cell route raises an unsupported grouped-agg shape for
# `min(<varchar>)` BESIDE any other aggregate). MIN/MAX over a NUMERIC input stays `_MIX_KIND_BASE` — the
# fixed-cell kernel owns it and this fold must never steal it.
comptime _MIX_KIND_STR: UInt8 = 2

# --- How a CD agg's input column is read into its EXACT Int64 distinct key. ---
# ⛔ THERE ARE NO PER-WIDTH READ CHANNELS HERE. This fold's CD arm classifies
# through `komira_agg_api.cd_distinct_key.cd_distinct_key_channel`, the SAME
# predicate the all-CD streaming sink reads, because two type lists for one
# contract would let `count(DISTINCT v)` and `count(*), count(DISTINCT v)`
# disagree about whether a type is supported at all. ⛔ Do not add a local
# channel table here. `_MIX_CDV_I64` is ONLY the inert filler a BASE (non-CD)
# plan puts in its unused `chan` slot.
comptime _MIX_CDV_I64: UInt8 = 0


@fieldwise_init
struct _MixAggPlan(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """One aggregate's resolved fold plan. POD by construction (the output NAME
    lives in a parallel `List[String]`, so this stays implicitly copyable and can
    be indexed without a heap copy in the per-row loop)."""

    var kind: UInt8      # _MIX_KIND_CD | _MIX_KIND_BASE
    var func: UInt8      # the plan AGG_* tag
    var src_col: Int     # batch column index; -1 for a bare COUNT(*)
    var chan: UInt8      # CD: the `cd_distinct_key_channel` code. BASE: unused.
    var src_is_int: Bool  # BASE: int-family input (else float-family)
    var slot: Int        # index into the per-group CD-set / base-cell list


@fieldwise_init
struct _MixBaseCell(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """One (group, base agg) fixed accumulator. `n` is the CONTRIBUTING count —
    non-null input rows for COUNT(col)/SUM/MIN/MAX/MEAN, and every row of the
    group for a bare COUNT(*). `n == 0` is what makes SUM/MIN/MAX/MEAN emit NULL,
    and `n == 1` marks the first contributing value for MIN/MAX seeding."""

    var i_acc: Int64
    var f_acc: Float64
    var n: Int64


# =============================================================================
# The PRE-GATE — a structural (schema-free) predicate, the sibling of
# `agg_all_count_distinct` / `extended_agg_servable`.
# =============================================================================


def agg_mixed_count_distinct_servable(imm agg_data: AggregateData) -> Bool:
    """True iff `agg_data` MIXES at least one `COUNT(DISTINCT <col>)` with at
    least one fixed-cell aggregate, and every key / agg input is a plain col_ref
    (or a bare `COUNT(*)`). This is the shape that matches no other arm of
    `_run_agg_over_batch`; `fold_mixed_count_distinct_over_batch` serves it.

    Structural ONLY — every DType question is resolved at fold time against the
    actual batch schema (the same division of labour `extended_agg_servable`
    uses). Returns False for an all-CD node (arm 1 owns it, byte-identically),
    for an all-fixed-cell node (arm 3 owns it), and for any node containing an
    op outside {COUNT_DISTINCT, SUM, COUNT, MIN, MAX, MEAN} — notably MEDIAN /
    LARGEST_K / CORR / STDDEV_SAMP / VAR_SAMP, which stay OUT of this arm so the
    extended fold keeps every shape it already serves."""
    var n_aggs = len(agg_data.agg_exprs)
    # A MIX needs one of each, so fewer than two aggregates can never be one.
    if n_aggs < 2:
        return False
    var n_cd = 0
    var n_base = 0
    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        var f = ae.func
        if f == AGG_COUNT_DISTINCT:
            if not ae.child:
                return False
            if not _cd_strip_alias_col_ref(ae.child.value()):
                return False
            n_cd += 1
            continue
        if (
            f != AGG_SUM
            and f != AGG_COUNT
            and f != AGG_MIN
            and f != AGG_MAX
            and f != AGG_MEAN
        ):
            return False
        if f == AGG_COUNT and not ae.child:
            # A bare COUNT(*) — no input column to resolve.
            n_base += 1
            continue
        if not ae.child:
            return False
        if not _cd_strip_alias_col_ref(ae.child.value()):
            return False
        n_base += 1
    if n_cd < 1 or n_base < 1:
        return False
    for k in range(len(agg_data.group_by)):
        ref ke = agg_data.group_by[k]
        if not _cd_strip_alias_col_ref(ke):
            return False
    return True


# =============================================================================
# The WIDER gate: an OFF-CELL aggregate is a
# COUNT(DISTINCT) **or** a MIN/MAX over a STRING column.
# =============================================================================
#
# ★ WHY A SECOND GATE AND NOT A RELAXATION OF THE ONE ABOVE. The predicate above
# is structural — it reads the plan and never a schema — and that is sound for
# COUNT(DISTINCT), whose op TAG alone settles that it is off-cell.
# A MIN/MAX is different: `min(<varchar>)` is off-cell and `min(<bigint>)` is a
# fixed-width cell the PARALLEL kernel already serves, and the two are the SAME
# plan node. A structural gate cannot tell them apart, so admitting MIN/MAX
# structurally would route every numeric `min(v), count(*)` into this SERIAL
# fold — a silent, large slowdown, and at `_run_agg_over_batch` a RAISE where
# the fixed-cell route answers.
#
# So the question is split in two, and BOTH halves are needed:
#   * `agg_mixed_offcell_candidate` — structural, cheap, a SUPERSET of
#     `agg_mixed_count_distinct_servable`. It is what a caller with no schema in
#     hand may ask, and a `True` means "ask again with a schema".
#   * `mixed_offcell_servable_for_schema` — resolves the MIN/MAX input DTypes
#     against a REAL schema (a parquet footer at the streaming leaf, the batch
#     schema at the resident leaf) and is the ONLY predicate a caller may turn a
#     decline into a RAISE on.
# The fold itself re-resolves against the batch it is handed and DECLINES if no
# off-cell aggregate survives — it is the last word, so neither gate can make it
# answer a shape it cannot serve.


def _mix_is_minmax(f: UInt8) -> Bool:
    return f == AGG_MIN or f == AGG_MAX


def agg_mixed_offcell_candidate(imm agg_data: AggregateData) -> Bool:
    """Structural (schema-free) gate for the mixed fold, WIDER than
    `agg_mixed_count_distinct_servable`: every group key and agg input is a plain
    col_ref (or a bare `COUNT(*)`), every op is in
    {COUNT_DISTINCT, SUM, COUNT, MIN, MAX, MEAN}, there are >= 2 aggregates, and
    the node is one of the two MIXED shapes this fold serves:

      1. >= 1 COUNT(DISTINCT) mixed with >= 1 other aggregate  (the
         shape `agg_mixed_count_distinct_servable` states — this clause is a
         strict superset of it);
      2. >= 1 MIN/MAX mixed with >= 1 SUM/COUNT/MEAN  (the
         `min(url), count(*)` / `avg(..), count(*), min(referer)` shape).
         Whether the MIN/MAX is actually OFF-CELL is a DType question this
         predicate deliberately does not answer — see the module note above.

    An ALL-MIN/MAX node is NOT a candidate: `fold_grouped_string_minmax_over_batch`
    owns it (all-string) and the fixed-cell kernel owns it (all-numeric), and
    taking it here would steal from one of them. An ALL-CD node is not one either
    (arm 1 owns it, byte-identically)."""
    var n_aggs = len(agg_data.agg_exprs)
    if n_aggs < 2:
        return False
    var n_cd = 0
    var n_minmax = 0
    var n_plain = 0
    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        var f = ae.func
        if f == AGG_COUNT_DISTINCT:
            if not ae.child:
                return False
            if not _cd_strip_alias_col_ref(ae.child.value()):
                return False
            n_cd += 1
            continue
        if (
            f != AGG_SUM
            and f != AGG_COUNT
            and f != AGG_MIN
            and f != AGG_MAX
            and f != AGG_MEAN
        ):
            return False
        if f == AGG_COUNT and not ae.child:
            n_plain += 1
            continue
        if not ae.child:
            return False
        if not _cd_strip_alias_col_ref(ae.child.value()):
            return False
        if _mix_is_minmax(f):
            n_minmax += 1
        else:
            n_plain += 1
    for k in range(len(agg_data.group_by)):
        ref ke = agg_data.group_by[k]
        if not _cd_strip_alias_col_ref(ke):
            return False
    if n_cd >= 1 and (n_minmax + n_plain) >= 1:
        return True
    return n_minmax >= 1 and n_plain >= 1


def mixed_offcell_servable_for_schema(
    imm agg_data: AggregateData, imm schema: Schema
) -> Bool:
    """`agg_mixed_offcell_candidate` PLUS the DType half: the node carries at
    least one aggregate this fold serves and the fixed-cell kernel does not — a
    COUNT(DISTINCT), or a MIN/MAX whose input column is STRING / LARGE_STRING in
    `schema`.

    ⛔ THIS IS THE ONLY PREDICATE A CALLER MAY RAISE ON. A node that passes the
    structural gate but fails here is an ORDINARY fixed-cell aggregate
    (`min(v), count(*)` over bigints) whose right home is the parallel kernel;
    turning that into a raise, or into a serial fold, is what this split exists
    to prevent."""
    if not agg_mixed_offcell_candidate(agg_data):
        return False
    for a in range(len(agg_data.agg_exprs)):
        ref ae = agg_data.agg_exprs[a]
        if ae.func == AGG_COUNT_DISTINCT:
            return True
        if not _mix_is_minmax(ae.func):
            continue
        if not ae.child:  # cov: unreachable the candidate gate above requires an input for every MIN/MAX
            continue  # cov: unreachable see the line above
        var in_opt = _cd_strip_alias_col_ref(ae.child.value())
        if not in_opt:  # cov: unreachable the candidate gate above requires every MIN/MAX input to be a column
            continue  # cov: unreachable see the line above
        var ci = _cd_col_idx(schema, in_opt.value())
        if ci < 0:
            continue
        var at = schema.field_at_unchecked(ci).arrow_type
        if at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
            return True
    return False


# =============================================================================
# ⭐ THE SCALE CEILING — THE ROW CEILING IS A MEMORY BOUND, SO IT IS DERIVED
# FROM WHAT THE FOLD ALLOCATES.
# =============================================================================
#
# ★ WHY NOT ARM 1'S CONSTANT. Arm 1's `_CD_FOLD_MAX_ROWS` (8,000,000) is a
# ROUTING choice — an all-CD node it declines is picked up by
# `CountDistinctAggSink`, the PARALLEL streaming sink, which serves
# `count(DISTINCT user_id) GROUP BY region_id` over a full benchmark-scale
# table. NOTHING stands behind the MIXED arm: every other route declines a CD
# (the 0-key scalar fold's op-set, `extended_agg_servable`, the fixed-cell
# descriptor build), so here a decline means REFUSE THE QUERY — after the
# caller has decoded the whole leaf. The same number would therefore refuse
# that query with a `sum`, a `count(*)` and an `avg` beside the
# COUNT(DISTINCT).
#
# ⭐ ONE CEILING, NOT ONE PER ACCUMULATOR KIND. A node carrying a STRING
# MIN/MAX does not get a lower cap, because the string-value arm has no
# per-row term the other arms lack:
#
#   * `size_of[String]()` is 24 on Mojo 1.0.0 with NO small-string
#     optimisation, so staging one owned `String` per row would cost 24 B of
#     struct plus the value's own heap allocation per row, plus a full COPY of
#     the column from `column_as_string` (`Column.as_string`: "The data is
#     COPIED"). This fold does none of that. It adopts the Arrow `StringArray`
#     (zero-copy where the column allows it), reads each cell through
#     `get_span`, and keeps a per-(group, aggregate) ROW INDEX, so on a
#     share-eligible column the arm costs nothing per row at all.
#
#   ⚠ WHAT IS LEFT IS NOT ZERO AND THE NEXT ROW OF THIS BLOCK SAYS SO. A
#   DICTIONARY or LARGE_STRING input takes the dense `column_as_string`
#   decode. The reason that does not buy a second ceiling is NOT that it is
#   free — it is that a STRING GROUP KEY pays the very same decode on the
#   CD-only arm too, so it is not a term the string-value arm has and the other
#   lacks. Two ceilings would then mean one of them is not derived from what it
#   bounds. Do not add a per-row figure here that has not been measured.
#
# ============================ THE ARITHMETIC =================================
#
# What this fold allocates ON TOP of the resident batch it is handed. ⚠ EVERY
# "bytes" figure below is the REQUESTED size; the allocator's own per-chunk
# header and size-class rounding are ON TOP and are NOT quantified here.
#
#   PER ROW                                                     bytes/row
#   ---------------------------------------------------------- ----------
#   each GROUP KEY column (`_cd_extract_native_key_col`)
#     null flag + precomputed hash                                 9
#     + INT32/INT64 key: the widened i64 value                     8
#     + STRING key: a COPY of the column (offsets + payload)  4 + mean_bytes
#   each COUNT(DISTINCT): Int64 distinct key + null flag            9
#   each fixed-cell agg over a column: i64/f64 value + null flag    9
#   a bare COUNT(*)                                                 0
#   ⭐ each STRING MIN/MAX, when the column can be SHARED             0
#   ⚠ each STRING MIN/MAX, when it CANNOT be              4 + mean_bytes
#
# ⛔⛔ THAT LAST ROW IS NOT A FOOTNOTE, AND WRITING A BARE "0" THERE WOULD BE
# WRONG. The fold takes the zero-copy arm only when
# `Column.can_share_as_string()` holds, which is `arrow_type == STRING` AND an
# offsets buffer AND `_offset == 0`. The other two admitted shapes fall through
# to `RecordBatch.column_as_string`, which is O(rows):
#
#   * a DICTIONARY-encoded column is DECODED into a dense `StringArray` — one
#     `offsets` entry and one payload copy per ROW, not per dictionary entry.
#     This is the live case, not a hypothetical: the Parquet reader emits
#     DICTIONARY for a BYTE_ARRAY column under `preserve_dict=True`, and
#     `column_as_string`'s own header records the decode and why it must run
#     BEFORE the schema-tag repair.
#   * a LARGE_STRING column is admitted by the plan gate above and refused by
#     `can_share_as_string` (which requires STRING), so it takes the same
#     fall-through — where `column_as_string` NARROWS it back to 32-bit
#     offsets, which is a full re-expression of both buffers, i.e. O(rows)
#     again. ⚠ Above `ARROW_INT32_OFFSET_MAX` data bytes that arm RAISES
#     instead, naming `column_as_large_string`. That is fail-CLOSED and costs
#     nothing, but it means a LARGE_STRING MIN/MAX input over ~2 GiB does not
#     reach this fold's ceiling at all — it is refused one layer down, with a
#     message about offsets rather than about rows.
#
# ⚠ NO SINGLE MULTIPLIER IS QUOTED for the string-value arm against per-row
# staging, BECAUSE THE RATIO DEPENDS ON `mean_bytes`. Staging would cost
# (4 + mean_bytes) for the copy + (24 + mean_bytes) for an owned `String` + 1
# for a null flag per row; this fold pays either 0 (share-eligible) or
# `4 + mean_bytes` (dictionary / LARGE_STRING).
#
#   PER GROUP
#   ---------------------------------------------------------------------
#   keyrow + hash + row count (three flat parallel lists)          24
#   the open-address `table`, 8 B per SLOT at load factor 0.7 and
#     a power-of-two capacity, i.e. 11.4 .. 22.9 B per GROUP       ~16
#   ⚠ THREE inner `List`s, one per group — `slot_sets[g]`,
#     `slot_cells[g]`, `slot_str_bestrow[g]` — each a header
#     stored INLINE in its outer list (pointer + size +
#     capacity, 3 machine words). UNCONDITIONAL:                   72
#     + each NON-EMPTY one also takes its own heap allocation,
#       so a node with 0 CD aggs pays the `slot_sets` header
#       and no buffer. Not quantified: see the allocator note.
#   per (group, string agg): the retained ROW index                 8
#   per (group, base agg): one `_MixBaseCell`                      24
#   per (group, CD agg): a `Set[Int64]` sized by that group's
#     DISTINCT CARDINALITY — the one term with no constant bound,
#     and it scales with distinct values, never with rows.
#
# ⚠ THE THREE INNER-LIST HEADERS ARE CHARGED PER GROUP EVEN WHEN THE LIST IS
# EMPTY. The fixed per-group terms above are 24 + ~16 + 72 = ~112 B/group:
# ~0.34 GB at 3M groups before a single `Set` or `_MixBaseCell` — small beside
# the per-row side tables at a large leaf, and NOT small for a
# high-cardinality key, where it is the term that grows.
#
# ⚠ THE ONE REMAINING UNCONDITIONAL PER-ROW STRING TERM IS THE GROUP KEY, NOT
# THE VALUE. `_cd_extract_native_key_col` reaches a STRING key through
# `batch.column_as_string(col_idx)` — the copy, on every column, with no
# `can_share_as_string` arm at all. That cost is identical on the CD-only and
# the string-value arms, it is priced into the constant below, and it is stated
# here rather than fixed here because that function is shared with the all-CD
# fold. ⭐ It is the next thing to look at if this ceiling has to move, and
# the fix is the `can_share_as_string` / `share_as_string` pair this fold
# uses for the VALUE column, applied one function over.
#
# ⛔ THE CEILING IS A REFUSAL, NOT A BUDGET. It is deliberately NOT unbounded: a
# serial fold handed an arbitrarily large leaf would allocate until the process
# died, and a SIGKILL is a worse answer than a legible cap error.
# =============================================================================


# ⭐ ONE CEILING, for the reason the block above derives: no off-cell
# accumulator has a per-row term the other lacks. A STRING MIN/MAX's remaining
# per-row term (the dictionary/LARGE_STRING fall-through) is the SAME term a
# STRING GROUP KEY pays unconditionally on BOTH arms, so it cannot justify a
# second, lower number for the string-value arm specifically.
#
# Sized to clear the ClickBench `hits` table with headroom, and bounded so a
# runaway leaf still refuses rather than allocating until the process is
# killed. Two shapes at this ceiling:
#
#   * 1 INT64 key, 1 CD, 2 numeric cells, 1 COUNT(*):
#     9 + 8 + 9 + 9 + 9 = 44 B/row -> ~5.6 GB of side tables.
#   * 1 STRING key, 1 numeric cell, 1 COUNT(*), 1 STRING MIN/MAX, with
#     mean_bytes ~82 on both string columns:
#
#     key    (9 + 4 + 82)        ~95 B/row
#     numeric aggregand            9 B/row
#     count(*)                     0
#     string MIN/MAX               0 B/row shared, ~86 B/row decoded
#     -----------------------------------------------------------------
#     ~104 B/row shared  ->  ~13 GB
#     ~190 B/row decoded ->  ~24 GB
#
# ⛔ SO THE WORST ADMITTED SHAPE AT THIS CEILING IS NOT SMALL: 128,000,000 rows
# under a STRING group key plus a dictionary-encoded STRING MIN/MAX is ~24 GB of
# side tables. THE CEILING IS A ROW COUNT SIZED AGAINST A BENCHMARK TABLE, NOT A
# BYTE BUDGET DERIVED FROM A WORST-CASE SCHEMA, and this block says so rather
# than implying a safety it does not have. A byte-derived ceiling is the honest
# successor; what the one ceiling does guarantee is that the string-VALUE arm
# costs no more per row than the key beside it.
# ⚠ Every figure here is the FOLD's side tables. The collected leaf itself is a
# separate, larger allocation that exists whichever arm serves the node.
comptime _MIX_FOLD_MAX_ROWS: Int = 128_000_000


# =============================================================================
# ⛔ THE TEST LOWERING — ONE-DIRECTIONAL, AND THAT IS THE WHOLE POINT.
# =============================================================================
#
# The `lowered_to` argument may only make the ceiling SMALLER. It is `min()`,
# never assignment, so no caller can hand this serial fold a
# bigger budget than the arithmetic above sized for it — the refusal the scale
# ceiling block calls "a refusal, not a budget" is not reachable from config.
#
# ★ WHY IT EXISTS AT ALL. The derived ceiling is 128,000,000 rows. A test that
# wants to exercise the BOUNDARY — which side of it the decision is taken on —
# would otherwise have to write a 128M-row parquet fixture, which is not a unit
# test. `_agg_inmem_max_rows` (`agg_node_exec`) carries the identical
# affordance for the identical reason and states it in its own docstring: "the
# regression test sets it LOW so a small fixture deterministically exercises the
# decline boundary". This is that idiom, minus the half that can raise a bound.
#
# ⚠ A non-positive value is IGNORED (the derived ceiling stands),
# for the same reason `_agg_inmem_max_rows` ignores one: a guard that a typo can
# switch off is not a guard.
# =============================================================================
def _mix_fold_ceiling_test_floor(derived: Int, lowered_to: Int) -> Int:
    """`derived`, LOWERED (never raised) by a positive `lowered_to`."""
    if lowered_to <= 0:
        return derived
    return lowered_to if lowered_to < derived else derived


def mixed_offcell_row_ceiling_for_schema(
    imm agg_data: AggregateData, imm schema: Schema, lowered_to: Int = 0
) -> Int:
    """The largest resident batch this SERIAL fold will accept for `agg_data`
    over `schema`, in ROWS. See THE ARITHMETIC in the scale ceiling block above
    for what it bounds, term by term.

    ⭐ ONE NUMBER FOR EVERY NODE. The string MIN/MAX arm reads its input in
    place and keeps a row index per group, so it has no per-row term the CD arm
    lacks and there is nothing for a second number to price.

    Both the resident-batch fold and the parquet-leaf collect driver read it, so
    the two cannot disagree about what is servable — a driver with a ceiling of
    its own would decode a whole leaf the fold then refuses.

    A positive `lowered_to` lowers the ceiling to it and never raises it (THE
    TEST LOWERING above); 0, the default, leaves the derived ceiling."""
    # ⚠ TAKES THE NODE AND THE SCHEMA, ON PURPOSE. It is the ONE place
    # this ceiling is decided, and both drivers plus the fold itself read it —
    # so when a future accumulator DOES introduce a per-row term (a STRING
    # GROUP KEY's column copy is the live candidate; see THE ARITHMETIC above)
    # the derivation has its operands already in hand and no call site changes.
    _ = agg_data
    _ = schema
    return _mix_fold_ceiling_test_floor(_MIX_FOLD_MAX_ROWS, lowered_to)


# =============================================================================
# Column emit helpers — a value list + a per-row null mask -> an Arrow column.
# =============================================================================


def _mix_any_null(imm nulls: List[Bool]) -> Bool:
    for i in range(len(nulls)):
        if nulls[i]:
            return True
    return False


def _mix_col_i64(
    imm vals: List[Int64], imm nulls: List[Bool], any_null: Bool
) raises -> Column[HeapRegion]:
    """An INT64 column over `vals`, NULL wherever `nulls[i]`. When no cell is
    null the column carries NO validity bitmap at all (byte-identical to every
    other non-nullable INT64 emit in the agg family)."""
    var n = len(vals)
    if not any_null:
        var arr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            arr._typed_ptr_mut()[i] = vals[i]
        return Column.from_primitive[DType.int64](arr^)
    var narr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if nulls[i]:
            narr._typed_ptr_mut()[i] = Int64(0)
            narr.validity.value().clear(i)
            nc += 1
        else:
            narr._typed_ptr_mut()[i] = vals[i]
    # The AUTHORITATIVE null_count assignment (the `_scalar_null_i64` idiom) —
    # a consumer that gates on `null_count` must not see 0 over a cleared bit.
    narr.null_count = nc
    return Column.from_primitive[DType.int64](narr^)


def _mix_col_f64(
    imm vals: List[Float64], imm nulls: List[Bool], any_null: Bool
) raises -> Column[HeapRegion]:
    """A FLOAT64 column over `vals`, NULL wherever `nulls[i]`. The F64 twin of
    `_mix_col_i64`."""
    var n = len(vals)
    if not any_null:
        var arr = PrimitiveArray[DType.float64].allocate(n)
        for i in range(n):
            arr._typed_ptr_mut()[i] = vals[i]
        return Column.from_primitive[DType.float64](arr^)
    var narr = PrimitiveArray[DType.float64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        if nulls[i]:
            narr._typed_ptr_mut()[i] = Float64(0.0)
            narr.validity.value().clear(i)
            nc += 1
        else:
            narr._typed_ptr_mut()[i] = vals[i]
    narr.null_count = nc
    return Column.from_primitive[DType.float64](narr^)


def _mix_is_int_family(at: ArrowType) -> Bool:
    """The int-family agg-input envelope. Only INT64 / INT32 are READ below (the
    same two the sibling serial folds read); the wider int family declines rather
    than routing through an accessor that cannot serve it."""
    return at == ArrowType.INT64 or at == ArrowType.INT32


def _mix_is_float_family(at: ArrowType) -> Bool:
    return at == ArrowType.FLOAT64 or at == ArrowType.FLOAT32


# =============================================================================
# ⭐ The STRING best-value compare reads the ARROW BYTES IN PLACE. No owned `String` is built to decide it.
# =============================================================================
@always_inline
def _mix_str_row_is_before(
    imm sa: StringArray[HeapRegion], a: Int, b: Int
) -> Bool:
    """Cell `a` of `sa` sorts strictly before cell `b` of the SAME array.

    The same-array spelling of the four-argument form below, which holds the one
    definition. Every ordering rule — unsigned bytes, the length tie-break,
    validity being the caller's business — is stated there."""
    return _mix_str_row_is_before(sa, a, sa, b)


def _mix_str_row_is_before(
    imm sa: StringArray[HeapRegion],
    a: Int,
    imm sb: StringArray[HeapRegion],
    b: Int,
) -> Bool:
    """True iff cell `a` of `sa` sorts STRICTLY BEFORE cell `b` of `sb` in SQL's
    lexicographic byte order — the same ordering `String.__lt__`, the
    `ACC_MIN_UTF8` / `ACC_MAX_UTF8` column accumulators and
    `fold_grouped_string_minmax_over_batch` compute, decided WITHOUT
    materialising either operand.

    ⚠ VALIDITY IS NOT ITS BUSINESS AND THE CALLER MUST HAVE SETTLED IT. In
    Arrow a NULL cell and a genuine `''` are THE SAME ZERO-LENGTH SPAN
    (`from_strings_with_validity` gives a null row an `(offset, length=0)` slot);
    only the bitmap separates them. `_CDNativeKeyCol.row_eq` states the same
    constraint for the group-key compare.

    ⚠ UNSIGNED, AND EXPLICITLY SO. Both operands are `UInt8`, so `'z'` (0x7A)
    sorts before U+00E9's lead byte (0xC3). Read as SIGNED bytes 0xC3 is -61 and
    every non-ASCII answer inverts. That is also why this is a written-out loop
    rather than a `memcmp`: `memcmp` settles EQUALITY in `cd_grouped_fold`
    (`row_eq`) and its sign convention for an ORDERING compare is not something
    this module should be asserting on its behalf.

    ⚠ AND THE LENGTH TIE-BREAK IS NOT OPTIONAL. Comparing only the common prefix
    makes `"abc"` and `"abcd"` EQUAL, so a min/max fold would keep whichever it
    met first. A shorter operand that is a prefix of a longer one sorts BEFORE
    it — the last line, not an afterthought.

    ⭐ TWO ARRAYS, NOT ONE. The mixed fold reads the collect's batch LIST rather than one concatenated batch, so the group's
    retained best cell and the cell being offered to it live in different
    batches and therefore in different `StringArray`s. `sa`/`a` is the LEFT
    operand of the `<` and `sb`/`b` the right; passing the same array twice is
    the three-argument overload above.

    Encapsulation: the spans are zero-copy borrows of the two arrays' own data
    buffers, compiler-tracked through `get_span`'s origin. No `UnsafePointer`
    appears in this signature and none escapes this function."""
    var span_a = sa.get_span(a)
    var span_b = sb.get_span(b)
    var la = len(span_a)
    var lb = len(span_b)
    var n = la if la < lb else lb
    for i in range(n):
        var x = span_a[i]
        var y = span_b[i]
        if x != y:
            return x < y
    return la < lb


# ⛔ THE FLOAT DISTINCT KEY IS NOT DEFINED HERE. It is the IEEE bit pattern
# with `-0.0` folded onto `+0.0`, and it lives at
# `komira_agg_api.cd_distinct_key.cd_f64_distinct_key`, which BOTH this fold
# and the all-CD sink call, so their agreement is constructed instead of
# asserted. (A raw 8-byte bitcast read is right for FLOAT64, whose storage IS 8
# bytes, and WRONG for FLOAT32, where it strides 8 bytes over 4-byte cells.)

# =============================================================================
# The FOLD.
# =============================================================================


# =============================================================================
# THE FOLD READS THE COLLECT'S BATCH LIST, NOT ONE CONCATENATED BATCH.
# =============================================================================
#
# ★ WHY. Concatenating the collected row-group batches into ONE `RecordBatch`
#   (`concat_record_batches_column_parallel`) has a hard 2 GiB-per-column
#   ceiling: every Arrow `string` column addresses its payload with an Int32
#   offsets buffer, so a column whose batches sum past `ARROW_INT32_OFFSET_MAX`
#   cannot be emitted at all, and the concat raises
#
#     ArrowOffsetOverflow: at streaming concat(n-way, row-range tiled) a column
#     needs <N> data bytes for <M> values ...
#
#   A `min(<varchar>)` over a large leaf crosses it with every input batch
#   comfortably legal on its own; only the SUM is not.
#
# ★ WHY THE BATCH LIST AND NOT A 64-BIT-OFFSET CONCAT. The concat's own header
#   argues for raising rather than promoting, and its last reason is the
#   binding one: promoting would make the output SCHEMA A FUNCTION OF THE DATA
#   at a site whose consumers refuse exactly that. That consumer is not
#   hypothetical — it is `assert_leaf_schema_agrees`, which compares
#   `field_arrow_type(i)` against a resolution schema derived by
#   `_infer_expr_field` from the PLAN, before a single byte is read. A width
#   that depends on the byte total cannot be predicted there, ever. (The
#   `_varlen_offset_width_alias` precedent — a PROJECT passthrough carrying its
#   SOURCE's offset width — does NOT cover this: there the width is a function
#   of the source SCHEMA, which the inference can and does see.)
#
#   And promotion would not even lift this cell: the string MIN/MAX arm below
#   sends a LARGE_STRING input to `RecordBatch.column_as_string`, which NARROWS
#   it back to 32-bit offsets and raises above the same ceiling — the refusal
#   would move from the concat to `column_as_large_string`, not disappear.
#
# ★ WHAT THIS ARM WOULD NEED A CONCAT FOR: NOTHING. Every per-row input it reads
#   is flattened into its own `List` (`cd_vals`, `base_i64`, `base_f64`, the key
#   columns' `nulls` / `hashes` / `i64_vals`), and the two things it reads OUT
#   of Arrow — a STRING group key's bytes and a STRING MIN/MAX's bytes — it
#   reaches through `get_span` at a ROW INDEX. Carrying a BATCH INDEX beside
#   that row index is all a multi-batch fold needs. The retained identity is
#   PACKED as `(batch << 32) | row` into one `Int` slot, so the accumulator is 8
#   bytes per (group, string aggregate) and `-1` means "this group has seen no
#   value".
#
# ⇒ NO COLUMN IS EVER ASSEMBLED, so no offset ceiling is crossed on this route
#   AT ANY SCALE, and — because every batch stays exactly the `string` /
#   int32-offset column the collect produced — NO consumer anywhere sees an
#   offset width it would not see otherwise. That is the difference between
#   this and promotion: promotion widens a value that the operators' many
#   `bitcast[Scalar[DType.int32]]` offset reads take at 32 bits.
#
# ⚠ WHAT IT DOES NOT DO. It does not make an expensive leaf fast (a computed
#   group key such as a `REGEXP_REPLACE` per row, evaluated in the leaf's
#   MapOp, dominates such a query's wall time). It does not widen the fold's ROW
#   ceiling, which is decided on the pre-fold tally. It does not make the fold
#   parallel. And because no concatenated COPY of the columns is made, peak RSS
#   is lower than a concat route's, not higher.
# =============================================================================

@always_inline
def _mix_pack_row(b: Int, r: Int) -> Int:
    """Pack a (batch, row-within-batch) pair into one non-negative `Int`.

    The high 32 bits are the batch index, the low 32 the row. Both are bounded
    by the collect: a batch index is a `List` index and a row index is an Arrow
    array length, and `-1` stays available as the "unseen" sentinel because a
    packed value is never negative."""
    return (b << 32) | r


@always_inline
def _mix_batch_of(packed: Int) -> Int:
    """The batch index of a value packed by `_mix_pack_row`."""
    return packed >> 32


@always_inline
def _mix_row_of(packed: Int) -> Int:
    """The row-within-batch of a value packed by `_mix_pack_row`."""
    return packed & 0xFFFFFFFF


def _mix_schemas_agree(imm a: Schema, imm b: Schema) -> Bool:
    """True iff two input batches carry the SAME column names and `ArrowType`s,
    in the same order.

    ⛔ THE GATE THAT MAKES A MULTI-BATCH FOLD SOUND, AND IT IS NOT A FORMALITY.
    Every column index this fold resolves is resolved ONCE, against the first
    batch's schema, and then used on every batch; and `_CDNativeKeyCol.cell_eq`
    compares one batch's key cell against another's on the assumption that both
    are the same key of the same type. A batch list whose members disagree
    DECLINES here rather than being folded at a stale index. Nullability is not
    compared — it is not read by any index or compare this fold performs."""
    if a.num_columns() != b.num_columns():
        return False
    for i in range(a.num_columns()):
        if a.field_name(i) != b.field_name(i):
            return False
        if a.field_arrow_type(i) != b.field_arrow_type(i):
            return False
    return True


def _mix_keys_equal(
    imm key_cols: List[List[_CDNativeKeyCol]],
    packed_a: Int,
    b_batch: Int,
    b_row: Int,
    n_keys: Int,
) raises -> Bool:
    """True iff EVERY group key's cell at the PACKED row `packed_a` equals its
    cell at `(b_batch, b_row)` — the multi-batch `_cd_native_keys_equal`."""
    var a_batch = _mix_batch_of(packed_a)
    var a_row = _mix_row_of(packed_a)
    for k in range(n_keys):
        if not key_cols[a_batch][k].cell_eq(
            a_row, key_cols[b_batch][k], b_row
        ):
            return False
    return True


struct _MixFoldInputs(Movable):
    """Everything the mixed fold reads, extracted ONCE per input batch.

    Two addressing schemes live here and the distinction is load-bearing:

      * the flat per-row `List`s (`cd_vals`, `cd_nulls`, `base_*`) are indexed
        by a GLOBAL row number, `row_base[batch] + row` — they are plain scalars
        and concatenating them costs nothing;
      * anything read out of ARROW (`key_cols[batch][key]`,
        `str_cols[batch][slot]`) is indexed by (batch, row), because those are
        the buffers we are deliberately NOT concatenating.

    A retained row — a group's key representative (`slot_keyrows`) or a string
    aggregate's current best (`slot_str_bestrow`) — is stored PACKED
    (`_mix_pack_row`), which is the one form that can address both.

    Encapsulation: plain `List` / `StringArray` / `_CDNativeKeyCol` members. No
    `UnsafePointer`, no wildcard origin, no pointer field of any kind — the
    `StringArray`s here are the fold's own handles (shared or decoded) and own
    or Arc-alias their buffers."""

    var key_names: List[String]
    var key_cols: List[List[_CDNativeKeyCol]]
    var plans: List[_MixAggPlan]
    var out_names: List[String]
    var cd_vals: List[List[Int64]]
    var cd_nulls: List[List[Bool]]
    var base_i64: List[List[Int64]]
    var base_f64: List[List[Float64]]
    var base_nulls: List[List[Bool]]
    var str_cols: List[List[StringArray[HeapRegion]]]
    var rows_of: List[Int]
    var row_base: List[Int]
    var n_cd_slots: Int
    var n_base_slots: Int
    var n_str_slots: Int
    var n_rows: Int

    def __init__(out self):
        self.key_names = List[String]()
        self.key_cols = List[List[_CDNativeKeyCol]]()
        self.plans = List[_MixAggPlan]()
        self.out_names = List[String]()
        self.cd_vals = List[List[Int64]]()
        self.cd_nulls = List[List[Bool]]()
        self.base_i64 = List[List[Int64]]()
        self.base_f64 = List[List[Float64]]()
        self.base_nulls = List[List[Bool]]()
        self.str_cols = List[List[StringArray[HeapRegion]]]()
        self.rows_of = List[Int]()
        self.row_base = List[Int]()
        self.n_cd_slots = 0
        self.n_base_slots = 0
        self.n_str_slots = 0
        self.n_rows = 0


def _mix_extract_batch(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
    mut st: _MixFoldInputs,
    first: Bool,
) raises -> Bool:
    """Resolve + pre-extract ONE input batch into `st`. False = DECLINE.

    On `first` this also resolves the per-aggregate PLAN and the output names;
    on every later batch the plan is reused, which is sound because the caller
    has already proven every batch's schema identical (`_mix_schemas_agree`) and
    the resolution is a pure function of that schema.

    ⚠ THE SLOT NUMBERING IS RE-DERIVED PER BATCH AND MUST LAND ON THE SAME
    NUMBERS. It does, for the same reason: the counters below are advanced by
    the same branches in the same order over the same schema. The alternative —
    reading the slot back out of `st.plans[a]` — would silently accept a
    divergence instead of being unable to express one."""
    var n_aggs = len(agg_data.agg_exprs)
    var n_keys = len(agg_data.group_by)
    var n_rows = batch.num_rows()
    var bi = len(st.rows_of)
    st.rows_of.append(n_rows)
    st.row_base.append(st.n_rows)

    # --- Resolve + pre-extract the GROUP-KEY columns (arm 1's machinery). -----
    var kcols = List[_CDNativeKeyCol]()
    for k in range(n_keys):
        ref ke = agg_data.group_by[k]
        var kn_opt = _cd_strip_alias_col_ref(ke)
        if not kn_opt:
            return False
        var kn = kn_opt.value()
        var ki = _cd_col_idx(batch.schema, kn)
        if ki < 0:
            return False
        var kat = batch.column_arrow_type(ki)
        if not _cd_key_dtype_ok(kat):
            return False
        # NULL-BEARING KEY -> DECLINE. This fold forms no NULL group and the
        # fixed-cell kernel (arm 3) does, so serving a null-key row any other
        # way would make the ROW COUNT of a mixed query depend on which arm ran.
        # Asked of the column, not inferred.
        # ⚠ ASKED OF EVERY BATCH, not of the first: a null-free first row group
        # says nothing about the ones behind it.
        if batch.column_at(ki).null_count() != 0:
            return False
        var kc_opt = _cd_extract_native_key_col(batch, ki)
        if not kc_opt:  # cov: unreachable the extractor reads the same column type the dtype gate above admitted
            return False  # cov: unreachable see the line above
        kcols.append(kc_opt.take())
        if first:
            st.key_names.append(kn)
    st.key_cols.append(kcols^)

    # --- Resolve the per-agg plan + pre-extract each input column ONCE. -------
    # `out_taken` is seeded with the GROUP-KEY names because the output schema
    # emits keys first — that is the order `LogicalPlan.aggregate` filled its own
    # `seen_names` in, and `agg_out_field_name` disambiguates against it.
    var out_taken = st.key_names.copy()
    var scols = List[StringArray[HeapRegion]]()
    var n_cd_slots = 0
    var n_base_slots = 0
    var n_str_slots = 0

    for a in range(n_aggs):
        ref ae = agg_data.agg_exprs[a]
        var f = ae.func
        if first:
            st.out_names.append(agg_out_field_name(ae.alias_name, f, out_taken))

        if f == AGG_COUNT_DISTINCT:
            if not ae.child:
                return False
            var in_opt = _cd_strip_alias_col_ref(ae.child.value())
            if not in_opt:
                return False
            var ci = _cd_col_idx(batch.schema, in_opt.value())
            if ci < 0:
                return False
            # ★ ONE ADMISSION RULE, SHARED WITH THE SINK. This arm and the
            # all-CD streaming sink both classify through
            # `cd_value_type_supported` / `cd_distinct_key_channel`. With two
            # type lists for one contract, `count(DISTINCT v)` and
            # `count(*), count(DISTINCT v)` could disagree about whether a type
            # is supported AT ALL, over the same column in the same table — a
            # result that depends on the query's shape rather than its data.
            #
            # ⚠ THE TWO LISTS MUST COME FROM THE SAME READ. The values list
            # reads a NULL row's raw payload like any other (Arrow leaves it
            # unspecified) and the accumulate loop gates on `cd_nulls` — taking
            # one without the other would count a null row's garbage payload as
            # a distinct value.
            var at = batch.column_arrow_type(ci)
            if not cd_value_type_supported(at):
                return False
            var chan: UInt8 = cd_distinct_key_channel(at)
            var vals = cd_distinct_keys_for_column(batch, ci)
            var nulls = cd_null_mask_for_column(batch, ci)
            if first:
                st.cd_vals.append(List[Int64]())
                st.cd_nulls.append(List[Bool]())
                st.plans.append(
                    _MixAggPlan(
                        _MIX_KIND_CD, f, ci, chan, False, n_cd_slots
                    )
                )
            for r in range(len(vals)):
                st.cd_vals[n_cd_slots].append(vals[r])
            for r in range(len(nulls)):
                st.cd_nulls[n_cd_slots].append(nulls[r])
            n_cd_slots += 1
            continue

        # --- STRING MIN/MAX — over a STRING / LARGE_STRING input. -----------
        # The DType, not the op, is what decides: a STRING MIN/MAX is off-cell
        # (no fixed-width AggSpec cell exists for a variable-length value) and a
        # NUMERIC MIN/MAX is not. So this arm is entered only after resolving the
        # input column, and a numeric input falls straight through to the BASE
        # arm below, with the fixed-cell semantics.
        if _mix_is_minmax(f) and ae.child:
            var sin_opt = _cd_strip_alias_col_ref(ae.child.value())
            if not sin_opt:
                return False
            var sci = _cd_col_idx(batch.schema, sin_opt.value())
            if sci < 0:
                return False
            var sat = batch.column_arrow_type(sci)
            if sat == ArrowType.STRING or sat == ArrowType.LARGE_STRING:
                # ⭐ ADOPT THE COLUMN, DO NOT COPY
                # IT, AND DO NOT WALK IT HERE. There is no pre-extraction pass
                # at all: the fold below reads each cell's bytes in place and
                # keeps a ROW INDEX per group.
                #
                # ⚠ `share_as_string` vs `column_as_string` IS A REAL
                # DIFFERENCE, NOT A STYLE ONE. `Column.as_string()` — what
                # `column_as_string` falls through to — says so in its own
                # docstring: "The data is COPIED into a new StringArray", i.e.
                # one full duplicate of the offsets AND data buffers of the
                # column we are about to read exactly once. `share_as_string`
                # Arc-aliases the same buffers and is byte-identical by
                # construction (`can_share_as_string` gates the three cases
                # where it would not be). The fall-through is kept because it is
                # the only arm that decodes a DICTIONARY-encoded column, which
                # `can_share_as_string` correctly refuses.
                #
                # ⭐ The decision is taken PER BATCH: a row-group whose column
                # is a plain STRING shares even when a sibling row-group's is
                # DICTIONARY-encoded, where a concatenated column would be one
                # verdict for all of them.
                #
                # ⛔ AND THE FALL-THROUGH IS O(ROWS), SO THIS IS A TWO-ARMED
                # COST, NOT A FAST PATH BESIDE A SLOW ONE. `column_as_string`
                # DECODES a dictionary into a DENSE `StringArray` — one offset
                # and one payload copy per ROW, not per dictionary entry — and a
                # LARGE_STRING input lands here too (`can_share_as_string`
                # requires STRING). THE ARITHMETIC in the scale ceiling block
                # prices both arms, and the row ceiling is derived over the
                # EXPENSIVE one.
                if batch.column_at(sci).can_share_as_string():
                    scols.append(batch.column_at(sci).share_as_string())
                else:
                    scols.append(batch.column_as_string(sci))
                if first:
                    st.plans.append(
                        _MixAggPlan(
                            _MIX_KIND_STR,
                            f,
                            sci,
                            _MIX_CDV_I64,
                            False,
                            n_str_slots,
                        )
                    )
                n_str_slots += 1
                continue

        # --- BASE (fixed-cell) aggregate. -------------------------------------
        if f == AGG_COUNT and not ae.child:
            # A bare COUNT(*) reads no column; its cell counts every group row.
            if first:
                st.base_i64.append(List[Int64]())
                st.base_f64.append(List[Float64]())
                st.base_nulls.append(List[Bool]())
                st.plans.append(
                    _MixAggPlan(
                        _MIX_KIND_BASE, f, -1, _MIX_CDV_I64, True, n_base_slots
                    )
                )
            n_base_slots += 1
            continue
        if not ae.child:
            return False
        var bin_opt = _cd_strip_alias_col_ref(ae.child.value())
        if not bin_opt:
            return False
        var bci = _cd_col_idx(batch.schema, bin_opt.value())
        if bci < 0:
            return False
        var bat = batch.column_arrow_type(bci)
        var ivals = List[Int64]()
        var fvals = List[Float64]()
        var bnulls = List[Bool](capacity=max(n_rows, 1))
        var is_int: Bool
        if _mix_is_int_family(bat):
            is_int = True
            ivals = List[Int64](capacity=max(n_rows, 1))
            if bat == ArrowType.INT64:
                var c = batch.column_as_primitive_int64(bci)
                for r in range(n_rows):
                    if c.is_null(r):
                        bnulls.append(True)
                        ivals.append(Int64(0))
                    else:
                        bnulls.append(False)
                        ivals.append(Int64(c.get(r)))
            else:
                var c = batch.column_as_primitive_int32(bci)
                for r in range(n_rows):
                    if c.is_null(r):
                        bnulls.append(True)
                        ivals.append(Int64(0))
                    else:
                        bnulls.append(False)
                        # The narrow-signed WIDEN-fold: an INT32 source folds
                        # into the I64 cell, matching the fixed-cell kernel.
                        ivals.append(Int64(c.get(r)))
        elif _mix_is_float_family(bat):
            is_int = False
            fvals = List[Float64](capacity=max(n_rows, 1))
            if bat == ArrowType.FLOAT64:
                var c = batch.column_as_primitive_float64(bci)
                for r in range(n_rows):
                    if c.is_null(r):
                        bnulls.append(True)
                        fvals.append(Float64(0.0))
                    else:
                        bnulls.append(False)
                        fvals.append(Float64(c.get(r)))
            else:
                var c = batch.column_as_primitive_float32(bci)
                for r in range(n_rows):
                    if c.is_null(r):
                        bnulls.append(True)
                        fvals.append(Float64(0.0))
                    else:
                        bnulls.append(False)
                        fvals.append(Float64(c.get(r)))
        else:
            return False
        if first:
            st.base_i64.append(List[Int64]())
            st.base_f64.append(List[Float64]())
            st.base_nulls.append(List[Bool]())
            st.plans.append(
                _MixAggPlan(
                    _MIX_KIND_BASE, f, bci, _MIX_CDV_I64, is_int, n_base_slots
                )
            )
        for r in range(len(ivals)):
            st.base_i64[n_base_slots].append(ivals[r])
        for r in range(len(fvals)):
            st.base_f64[n_base_slots].append(fvals[r])
        for r in range(len(bnulls)):
            st.base_nulls[n_base_slots].append(bnulls[r])
        n_base_slots += 1

    st.str_cols.append(scols^)
    if first:
        st.n_cd_slots = n_cd_slots
        st.n_base_slots = n_base_slots
        st.n_str_slots = n_str_slots
    st.n_rows += n_rows
    _ = bi
    return True


def _mix_fold_and_emit(
    imm agg_data: AggregateData, imm st: _MixFoldInputs
) raises -> Optional[RecordBatch]:
    """The serial fold over every extracted batch, and the readback."""
    var n_aggs = len(agg_data.agg_exprs)
    var n_keys = len(agg_data.group_by)
    var n_batches = len(st.rows_of)

    # --- The serial fold. ----------------------------------------------------
    # GROUPED: an open-address table over the composite NATIVE key hash, slots
    # assigned in FIRST-OCCURRENCE order (the same table + the same order arm 1
    # builds, so a mixed node's group ORDER matches the all-CD node's).
    # 0-KEY: one implicit group, created up front so an EMPTY input still emits
    # the one SQL-mandated identity row.
    #
    # ⚠ BATCH-OUTER / ROW-INNER, AND THE ORDER IS THE SEMANTICS. The batches are
    # visited in the order the collect returned them and each batch's rows in
    # row order, which is the order their concatenation would present — so
    # group FIRST-OCCURRENCE order, and therefore the emitted row order, is the
    # same as folding one concatenated batch.
    var slot_keyrows = List[Int]()
    var slot_hashes = List[UInt64]()
    var slot_rows = List[Int64]()
    var slot_sets = List[List[Set[Int64]]]()
    var slot_cells = List[List[_MixBaseCell]]()
    # STRING MIN/MAX: per (group, string agg) the PACKED (batch, row) of the current
    # best, or -1 for a group that has seen no non-null value yet.
    #
    # ⭐ A ROW IDENTITY, NOT A `String`, AND -1 REPLACES A SEPARATE any-seen
    # FLAG. The retained cell is rendered to a `String` exactly ONCE, at emit, so
    # the whole accumulator is 8 B per (group, string aggregate) and the fold
    # allocates nothing at all on the per-row path.
    #
    # ⚠ THE -1 SENTINEL IS DOING THE JOB OF A `seen` FLAG. The empty
    # string is a VALUE here — it is the min of any group holding it (a test
    # fixture's own answer) — so "best is empty" may never stand in for "nothing
    # was seen", and row 0 of batch 0 (packed: 0) is a perfectly good best. Only
    # a negative value means unseen, and `_mix_pack_row` never produces one.
    var slot_str_bestrow = List[List[Int]]()
    var n_groups = 0

    var cap = 1024
    var table = List[Int](capacity=cap)
    for _ in range(cap):
        table.append(-1)
    var mask = cap - 1

    if n_keys == 0:
        slot_keyrows.append(0)
        slot_hashes.append(UInt64(0))
        slot_rows.append(Int64(0))
        var fresh_sets = List[Set[Int64]]()
        for _s in range(st.n_cd_slots):
            fresh_sets.append(Set[Int64]())
        slot_sets.append(fresh_sets^)
        var fresh_cells = List[_MixBaseCell]()
        for _s in range(st.n_base_slots):
            fresh_cells.append(_MixBaseCell(Int64(0), Float64(0.0), Int64(0)))
        slot_cells.append(fresh_cells^)
        var fresh_best = List[Int]()
        for _s in range(st.n_str_slots):
            fresh_best.append(-1)
        slot_str_bestrow.append(fresh_best^)
        n_groups = 1

    for b in range(n_batches):
        var nb_rows = st.rows_of[b]
        var gbase = st.row_base[b]
        for r in range(nb_rows):
            # The GLOBAL row, for the flat per-row lists only.
            var g = gbase + r
            var slot: Int
            if n_keys == 0:
                slot = 0
            else:
                # A null key cannot reach here (a null-bearing key column
                # DECLINED above, for EVERY batch); the guard is kept so the
                # invariant is stated where it is relied on rather than only
                # where it is established.
                var key_null = False
                for k in range(n_keys):
                    if st.key_cols[b][k].nulls[r]:
                        key_null = True
                        break
                if key_null:
                    continue
                var h = UInt64(1469598103934665603)
                for k in range(n_keys):
                    h = _cd_hash_combine(h, st.key_cols[b][k].hashes[r])
                slot = -1
                var pos = Int(h & UInt64(mask))
                while True:
                    var e = table[pos]
                    if e < 0:
                        break
                    if slot_hashes[e] == h and _mix_keys_equal(
                        st.key_cols, slot_keyrows[e], b, r, n_keys
                    ):
                        slot = e
                        break
                    pos = (pos + 1) & mask
                if slot < 0:
                    slot = n_groups
                    table[pos] = slot
                    slot_keyrows.append(_mix_pack_row(b, r))
                    slot_hashes.append(h)
                    slot_rows.append(Int64(0))
                    var fresh_sets = List[Set[Int64]]()
                    for _s in range(st.n_cd_slots):
                        fresh_sets.append(Set[Int64]())
                    slot_sets.append(fresh_sets^)
                    var fresh_cells = List[_MixBaseCell]()
                    for _s in range(st.n_base_slots):
                        fresh_cells.append(
                            _MixBaseCell(Int64(0), Float64(0.0), Int64(0))
                        )
                    slot_cells.append(fresh_cells^)
                    var fresh_best = List[Int]()
                    for _s in range(st.n_str_slots):
                        fresh_best.append(-1)
                    slot_str_bestrow.append(fresh_best^)
                    n_groups += 1
                    # Grow + rehash at load factor 0.7 (arm 1's table, verbatim).
                    if n_groups * 10 >= cap * 7:
                        cap = cap * 2
                        mask = cap - 1
                        var ntable = List[Int](capacity=cap)
                        for _ in range(cap):
                            ntable.append(-1)
                        for s in range(n_groups):
                            var hp = Int(slot_hashes[s] & UInt64(mask))
                            while ntable[hp] >= 0:
                                hp = (hp + 1) & mask
                            ntable[hp] = s
                        table = ntable^

            slot_rows[slot] += Int64(1)
            ref sets = slot_sets[slot]
            ref cells = slot_cells[slot]
            ref sbestrow = slot_str_bestrow[slot]
            for a in range(n_aggs):
                ref p = st.plans[a]
                if p.kind == _MIX_KIND_CD:
                    if not st.cd_nulls[p.slot][g]:
                        sets[p.slot].add(st.cd_vals[p.slot][g])
                    continue
                if p.kind == _MIX_KIND_STR:
                    # NULL inputs are SKIPPED, matching every sibling serial fold
                    # (and DuckDB): a group whose values are all NULL emits NULL.
                    # ⚠ ASKED OF THE VALIDITY BITMAP, BEFORE ANY BYTE COMPARE — a
                    # NULL cell and a genuine `''` are the same zero-length span.
                    if st.str_cols[b][p.slot].is_null(r):
                        continue
                    var cur = sbestrow[p.slot]
                    if cur < 0:
                        # First non-null value this group has seen for this agg.
                        sbestrow[p.slot] = _mix_pack_row(b, r)
                        continue
                    var cb = _mix_batch_of(cur)
                    var cr = _mix_row_of(cur)
                    var better: Bool
                    if p.func == AGG_MIN:
                        better = _mix_str_row_is_before(
                            st.str_cols[b][p.slot],
                            r,
                            st.str_cols[cb][p.slot],
                            cr,
                        )
                    else:
                        better = _mix_str_row_is_before(
                            st.str_cols[cb][p.slot],
                            cr,
                            st.str_cols[b][p.slot],
                            r,
                        )
                    if better:
                        sbestrow[p.slot] = _mix_pack_row(b, r)
                    continue
                ref cell = cells[p.slot]
                if p.src_col < 0:
                    # A bare COUNT(*) counts EVERY row of the group.
                    cell.n += Int64(1)
                    continue
                if st.base_nulls[p.slot][g]:
                    continue
                cell.n += Int64(1)
                if p.func == AGG_COUNT:
                    continue
                # `cell.n == 1` is the FIRST contributing value (it was just
                # incremented), which is how MIN/MAX seed without a separate flag.
                if p.src_is_int:
                    var v = st.base_i64[p.slot][g]
                    if p.func == AGG_SUM or p.func == AGG_MEAN:
                        cell.i_acc += v
                    elif p.func == AGG_MIN:
                        if cell.n == Int64(1) or v < cell.i_acc:
                            cell.i_acc = v
                    else:
                        if cell.n == Int64(1) or v > cell.i_acc:
                            cell.i_acc = v
                else:
                    var v = st.base_f64[p.slot][g]
                    if p.func == AGG_SUM or p.func == AGG_MEAN:
                        cell.f_acc += v
                    # ⛔ NOT a bare `<` / `>`.
                    # IEEE comparisons are false against a NaN, so the answer
                    # would depend on ARRIVAL order: `{NaN, 5}` would keep the
                    # seed NaN for MIN, `{1, NaN}` would keep 1 for MAX. DuckDB
                    # orders floats TOTALLY (NaN above +inf): beside a
                    # count(DISTINCT v), min{NaN,-inf,2} = -inf and
                    # max{5,NaN} = NaN. The quotient order
                    # (float_quotient_order) is the model -- ⚠ NOT every
                    # route's: the row-format spill kernels,
                    # columnar_acc_typed_extra and agg_state_slab MinF32/MaxF32
                    # fold IEEE.
                    elif p.func == AGG_MIN:
                        if cell.n == Int64(1) or float_quotient_lt_f64(v, cell.f_acc):
                            cell.f_acc = v
                    else:
                        if cell.n == Int64(1) or float_quotient_gt_f64(v, cell.f_acc):
                            cell.f_acc = v

    # --- Readback: n_keys key cols (NATIVE DType) + n_aggs agg cols. ----------
    var rbb = RecordBatchBuilder.with_capacity(n_groups)
    var out_sb = SchemaBuilder()

    for k in range(n_keys):
        var is_string = st.key_cols[0][k].is_string
        var kat = st.key_cols[0][k].arrow_type
        if is_string:
            var svals = List[String](capacity=max(n_groups, 1))
            for g in range(n_groups):
                var pk = slot_keyrows[g]
                svals.append(
                    st.key_cols[_mix_batch_of(pk)][k].strs.get(_mix_row_of(pk))
                )
            var sa = StringArray.from_strings(svals)
            rbb.add_column(Column.from_string(sa^))
            out_sb.add_field(Field(st.key_names[k], ArrowType.STRING, False))
        elif kat == ArrowType.INT32:
            var arr = PrimitiveArray[DType.int32].allocate(n_groups)
            for g in range(n_groups):
                var pk = slot_keyrows[g]
                arr._typed_ptr_mut()[g] = st.key_cols[_mix_batch_of(pk)][
                    k
                ].i64_vals[_mix_row_of(pk)].cast[DType.int32]()
            rbb.add_column(Column.from_primitive[DType.int32](arr^))
            out_sb.add_field(Field(st.key_names[k], ArrowType.INT32, False))
        else:
            var arr = PrimitiveArray[DType.int64].allocate(n_groups)
            for g in range(n_groups):
                var pk = slot_keyrows[g]
                arr._typed_ptr_mut()[g] = st.key_cols[_mix_batch_of(pk)][
                    k
                ].i64_vals[_mix_row_of(pk)]
            rbb.add_column(Column.from_primitive[DType.int64](arr^))
            out_sb.add_field(Field(st.key_names[k], ArrowType.INT64, False))

    for a in range(n_aggs):
        ref p = st.plans[a]
        if p.kind == _MIX_KIND_STR:
            # The lexicographic per-group best, emitted as a STRING column —
            # value-identical to the ACC_MIN_UTF8 / ACC_MAX_UTF8 column kernel
            # and to `fold_grouped_string_minmax_over_batch`. Validity is
            # attached ONLY when some group saw no value, so a value-complete
            # column carries no bitmap (the `_mix_col_i64` any-null discipline).
            # ⭐ THE ONLY PLACE A `String` IS BUILT — once per GROUP, from the
            # cell this group retained. O(groups), never O(rows).
            #
            # ⚠ AND THE OUTPUT IS A PLAIN `string` COLUMN AT EVERY INPUT SCALE.
            # It holds one value per GROUP, never per row, so it is not the
            # buffer a concat could not address — which is why the batch-list
            # fold does not hand any downstream consumer an offset width it
            # would not see otherwise.
            var mvals = List[String](capacity=max(n_groups, 1))
            var mvalid = List[Bool](capacity=max(n_groups, 1))
            var any_unseen = False
            for g in range(n_groups):
                var br = slot_str_bestrow[g][p.slot]
                if br < 0:
                    mvals.append(String(""))
                    mvalid.append(False)
                    any_unseen = True
                else:
                    mvals.append(
                        st.str_cols[_mix_batch_of(br)][p.slot].get(
                            _mix_row_of(br)
                        )
                    )
                    mvalid.append(True)
            if any_unseen:
                var sa_out = StringArray.from_strings_with_validity(
                    mvals, mvalid
                )
                rbb.add_column(Column.from_string(sa_out^))
            else:
                var sa_out2 = StringArray.from_strings(mvals)
                rbb.add_column(Column.from_string(sa_out2^))
            out_sb.add_field(
                Field(st.out_names[a], ArrowType.STRING, any_unseen)
            )
            continue

        if p.kind == _MIX_KIND_CD:
            var cvals = List[Int64](capacity=max(n_groups, 1))
            var cnulls = List[Bool](capacity=max(n_groups, 1))
            for g in range(n_groups):
                cvals.append(Int64(len(slot_sets[g][p.slot])))
                cnulls.append(False)
            rbb.add_column(_mix_col_i64(cvals, cnulls, False))
            out_sb.add_field(Field(st.out_names[a], ArrowType.INT64, False))
            continue

        var f = p.func
        if f == AGG_COUNT:
            # COUNT(*) -> every row of the group; COUNT(col) -> non-null rows.
            # Both are non-null INT64 (0 is a real answer, never NULL).
            var vals = List[Int64](capacity=max(n_groups, 1))
            var nulls = List[Bool](capacity=max(n_groups, 1))
            for g in range(n_groups):
                if p.src_col < 0:
                    vals.append(slot_rows[g])
                else:
                    vals.append(slot_cells[g][p.slot].n)
                nulls.append(False)
            rbb.add_column(_mix_col_i64(vals, nulls, False))
            out_sb.add_field(Field(st.out_names[a], ArrowType.INT64, False))
            continue

        if f == AGG_MEAN:
            var vals = List[Float64](capacity=max(n_groups, 1))
            var nulls = List[Bool](capacity=max(n_groups, 1))
            for g in range(n_groups):
                ref cell = slot_cells[g][p.slot]
                if cell.n == Int64(0):
                    vals.append(Float64(0.0))
                    nulls.append(True)
                elif p.src_is_int:
                    vals.append(Float64(cell.i_acc) / Float64(cell.n))
                    nulls.append(False)
                else:
                    vals.append(cell.f_acc / Float64(cell.n))
                    nulls.append(False)
            var anynull = _mix_any_null(nulls)
            rbb.add_column(_mix_col_f64(vals, nulls, anynull))
            out_sb.add_field(Field(st.out_names[a], ArrowType.FLOAT64, anynull))
            continue

        # SUM / MIN / MAX — int-family folds into the I64 cell and emits INT64;
        # float-family folds into the F64 cell and emits FLOAT64. A group with
        # ZERO contributing (non-null) rows emits NULL, not 0.
        if p.src_is_int:
            var vals = List[Int64](capacity=max(n_groups, 1))
            var nulls = List[Bool](capacity=max(n_groups, 1))
            for g in range(n_groups):
                ref cell = slot_cells[g][p.slot]
                if cell.n == Int64(0):
                    vals.append(Int64(0))
                    nulls.append(True)
                else:
                    vals.append(cell.i_acc)
                    nulls.append(False)
            var anynull = _mix_any_null(nulls)
            rbb.add_column(_mix_col_i64(vals, nulls, anynull))
            out_sb.add_field(Field(st.out_names[a], ArrowType.INT64, anynull))
        else:
            var vals = List[Float64](capacity=max(n_groups, 1))
            var nulls = List[Bool](capacity=max(n_groups, 1))
            for g in range(n_groups):
                ref cell = slot_cells[g][p.slot]
                if cell.n == Int64(0):
                    vals.append(Float64(0.0))
                    nulls.append(True)
                else:
                    vals.append(cell.f_acc)
                    nulls.append(False)
            var anynull = _mix_any_null(nulls)
            rbb.add_column(_mix_col_f64(vals, nulls, anynull))
            out_sb.add_field(Field(st.out_names[a], ArrowType.FLOAT64, anynull))

    var out_batch = rbb.build(out_sb.build())
    return Optional[RecordBatch](out_batch^)


def fold_mixed_count_distinct_over_batch(
    imm agg_data: AggregateData,
    imm batch: RecordBatch,
) raises -> Optional[RecordBatch]:
    """Fold a MIXED `COUNT(DISTINCT ...)` + fixed-cell aggregate over ONE
    ALREADY-RESIDENT batch into a result RecordBatch (n_keys key cols + n_aggs
    agg cols, in the plan's own order), DECLINE-RETURNING.

    The single-batch spelling of `fold_mixed_count_distinct_over_batches`, for
    the resident-child call sites that genuinely hold one batch. Same code, same
    values; see the module header for the served shape, what declines and why,
    and the NULL / DType / naming contracts. Returns None for anything out of
    envelope — the caller raises a legible cap error; this never returns a wrong
    answer in place of a decline."""
    if not agg_mixed_offcell_candidate(agg_data):
        return None
    var n_rows = batch.num_rows()
    # The scale ceiling is THIS fold's own, not inherited from arm 1 — see
    # `mixed_offcell_row_ceiling_for_schema`. ⚠ It is ONE number and the call's
    # two arguments are not read; no term of it varies by node.
    if n_rows > mixed_offcell_row_ceiling_for_schema(agg_data, batch.schema):
        return None
    var st = _MixFoldInputs()
    if not _mix_extract_batch(agg_data, batch, st, True):
        return None
    # ⛔ NO OFF-CELL AGGREGATE SURVIVED THE DTYPE RESOLUTION -> DECLINE.
    if st.n_cd_slots == 0 and st.n_str_slots == 0:
        return None
    return _mix_fold_and_emit(agg_data, st)


def fold_mixed_count_distinct_over_batches(
    imm agg_data: AggregateData,
    imm batches: Slab[RecordBatch],
) raises -> Optional[RecordBatch]:
    """Fold a MIXED off-cell + fixed-cell aggregate over the collect's BATCH
    LIST, DECLINE-RETURNING. ⭐ See this section's header for why a list.

    The batches are folded IN LIST ORDER, each in row order, so the group
    first-occurrence order — and therefore the emitted row order — is identical
    to folding their concatenation. Nothing is assembled: the only thing a
    multi-batch fold adds over a single-batch one is a batch index beside the
    row index it already kept.

    ⛔ THE BATCHES MUST ALL CARRY THE SAME SCHEMA and this checks, rather than
    assumes it: every column index is resolved once against `batches[0]`.

    Args:
        agg_data: The aggregate node.
        batches: The collected leaf batches, in collect order — the `Slab` the
            concat-free collect returns, taken by reference and never copied. An
            EMPTY slab
            declines — there is no schema to resolve against, and an aggregate
            over no batch at all is the caller's empty-result case, not this
            fold's.
    """
    if not agg_mixed_offcell_candidate(agg_data):
        return None
    if len(batches) == 0:
        return None

    # ⚠ THE SCHEMA SOURCE IS THE FIRST *POPULATED* BATCH, NOT `batches[0]`. A
    # row group the pushed scan filter empties comes back as a 0-row batch, and
    # the streaming concat skips those when choosing the schema it stamps
    # (`streaming_concat_parallel.mojo`: `rows > 0 and b.num_columns() > 0`).
    # Resolving the plan against an empty leading batch would decline a query
    # the concat route serves.
    var src = -1
    for b in range(len(batches)):
        if batches[b].num_rows() > 0 and batches[b].num_columns() > 0:
            src = b
            break
    if src < 0:
        src = 0

    # ⛔ AGREEMENT IS ASKED OF THE POPULATED BATCHES ONLY, for the same reason:
    # an emptied row group carries no rows for any index to be wrong about.
    for b in range(len(batches)):
        if batches[b].num_rows() == 0:
            continue
        if not _mix_schemas_agree(batches[src].schema, batches[b].schema):
            return None

    var n_rows = 0
    for b in range(len(batches)):
        n_rows += batches[b].num_rows()
    # The same derived ceiling, decided on the TOTAL row count.
    if n_rows > mixed_offcell_row_ceiling_for_schema(
        agg_data, batches[src].schema
    ):
        return None

    # ⚠ A 0-ROW BATCH IS SKIPPED, NOT EXTRACTED. `column_as_string` /
    # `share_as_string` over an empty row-group buys nothing and the fold's inner
    # loop would iterate zero times anyway; skipping keeps the packed batch index
    # dense. If EVERY batch is empty the schema-source batch is still extracted,
    # because the plan and the output SCHEMA have to be resolved from something.
    var st = _MixFoldInputs()
    var any = False
    for b in range(len(batches)):
        if batches[b].num_rows() == 0:
            continue
        if not _mix_extract_batch(agg_data, batches[b], st, not any):
            return None
        any = True
    if not any:
        if not _mix_extract_batch(agg_data, batches[src], st, True):
            return None
    # ⛔ NO OFF-CELL AGGREGATE SURVIVED THE DTYPE RESOLUTION -> DECLINE.
    # `agg_mixed_offcell_candidate` admits `min(v), count(*)` structurally
    # because it cannot see that `v` is a bigint. If the resolution above found
    # neither a distinct SET nor a STRING best-value, EVERY aggregate here is a
    # fixed-width cell and the PARALLEL kernel owns the node. Serving it would
    # not be wrong, it would be SLOW — a single-threaded fold in place of the
    # parallel hash aggregate — so the fold refuses and the caller falls through
    # to the fixed-cell route.
    if st.n_cd_slots == 0 and st.n_str_slots == 0:
        return None
    return _mix_fold_and_emit(agg_data, st)
