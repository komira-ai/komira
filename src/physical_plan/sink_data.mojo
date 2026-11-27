# =============================================================================
# sink_data -- the sink payloads a segment's `sink_param_id` names
# =============================================================================
#
# The `*SinkData` structs of the PhysicalPlan IR (aggregation, sort, top-n,
# partition-by, partition top-n, as-of join, hash build and sort-merge-join
# build) and `is_explicit_nulls_first_request`, moved out of `physical_plan`
# unchanged so that file stays under 1000 lines. `physical_plan` imports every
# name here, so `from physical_plan.physical_plan import AggSinkData` still
# resolves; `PHYSICAL_PLAN_IR_VERSION` and its bump policy cover these structs
# as before. Inert data, like the rest of the IR.
# =============================================================================

from arrow.schema import RecordBatch, Schema
from plan_expr.null_order_policy import derived_nulls_first
from plan_expr.partition_expr import PartitionExpr
from plan_ir.logical_plan import ExprArray, AggExprArray, AsofTolerance

# =============================================================================
# AggSinkData -- configuration for aggregation sink
# =============================================================================

struct AggSinkData(Movable):
    """Configuration for a hash aggregation sink.

    Fields:
        group_by_exprs: Expressions for group-by keys.
        agg_exprs: Aggregation expressions (SUM, COUNT, etc.).
        output_schema: Expected output schema after aggregation.
        presorted: True when the input plan advertises a sort order whose
            prefix equals the group-by keys in order (i.e. the S3
            streaming-sort strategy is candidate-eligible). Computed by
            the plan compiler; consumed by the engine's hash-aggregation
            sink via `choose_strategy` (`agg_api`). The compiler and
            the sink are not in this tree. Defaults False for
            call sites that do not know the input order.
        estimated_groups: Plan-time cardinality estimate (from Parquet
            stats / logical plan hints). 0 means "unknown" -- the sink
            then defaults to the low-cardinality S1 path. Consumed once
            at sink resize_worker_state() by `choose_strategy` (fed from
            Parquet stats, not runtime sampling).
    """
    var group_by_exprs: ExprArray
    var agg_exprs: AggExprArray
    var output_schema: Schema
    var presorted: Bool
    var estimated_groups: Int

    def __init__(
        out self,
        var group_by_exprs: ExprArray,
        var agg_exprs: AggExprArray,
        var output_schema: Schema,
        presorted: Bool = False,
        estimated_groups: Int = 0,
    ):
        self.group_by_exprs = group_by_exprs^
        self.agg_exprs = agg_exprs^
        self.output_schema = output_schema^
        self.presorted = presorted
        self.estimated_groups = estimated_groups

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass

# =============================================================================
# SortSinkData -- configuration for sort sink
# =============================================================================

struct SortSinkData(Movable):
    """Configuration for a full sort sink.

    Fields:
        sort_keys: Column names to sort by.
        descending: Per-key sort direction flags.
        memory_budget: Bytes; 0 = unlimited (concat-then-sort path).
            >0 = route through the engine's external sorter with
            input-side spill at this byte budget. Threaded by the plan
            compiler from the scheduler's operator budget (the engine and
            the compiler are not in this tree).
        nulls_first: Per-key EXPLICIT NULL placement, or EMPTY for "derive".

    ★★ `nulls_first` IS EMPTY-MEANS-DERIVE, AND THAT IS THE WHOLE COMPATIBILITY
    STORY. An EMPTY list means "the engine's
    own derived default", `null_order_policy.derived_nulls_first(descending[i])`
    (`logical_plan_variants._resolve_nulls_first`) — so a construction site
    that does not ask gets the default arm of the engine's sort sink.

    ⛔ AN EMPTY LIST IS NOT `[False, False, ...]`. Spelling the default as
    all-false would hard-code one placement at every construction site;
    spelling the policy OUT at each construction site
    would put the policy in many places. Empty says "I am not asking", which is a
    THIRD state neither boolean can encode.

    ⚠ LENGTH IS CHECKED WHERE IT IS READ, NOT HERE. A non-empty list of the
    wrong length is a producer bug, and the engine's sort sink (not in this
    tree) refuses it BY NAME rather than indexing past the end.
    """
    var sort_keys: List[String]
    var descending: List[Bool]
    var memory_budget: Int
    var nulls_first: List[Bool]

    def __init__(
        out self,
        var sort_keys: List[String],
        var descending: List[Bool],
        memory_budget: Int = 0,
        var nulls_first: List[Bool] = List[Bool](),
    ):
        self.sort_keys = sort_keys^
        self.descending = descending^
        self.memory_budget = memory_budget
        self.nulls_first = nulls_first^

# =============================================================================
# TopNSinkData -- configuration for TopN sink
# =============================================================================

struct TopNSinkData(Movable):
    """Configuration for a TopN sink (fused sort + limit).

    Fields:
        sort_keys: Column names to sort by.
        descending: Per-key sort direction flags.
        n: Number of rows to keep.
        nulls_first: Per-key EXPLICIT NULL placement, or EMPTY for "derive".
            Same empty-means-derive contract as `SortSinkData.nulls_first` —
            read that field's note; it is stated once.
        offset: Rows of the sort order to skip before the `n` kept: the sink
            answers rows [offset, offset + n) of its input in sort order
            (`ORDER BY ... LIMIT n OFFSET offset`). 0, the default, is the
            plain top-N.

    ⚠ ON A TOP-N THE PLACEMENT IS NOT COSMETIC: it decides WHICH `n` ROWS COME
    BACK, not merely where they sit. `ORDER BY v LIMIT 3` over a column with
    three NULLs returns the three NULLs under NULLS FIRST and none of them under
    NULLS LAST. That is why the field is carried here at all rather than being
    applied as a presentation pass after the slice.
    """
    var sort_keys: List[String]
    var descending: List[Bool]
    var n: Int
    var nulls_first: List[Bool]
    var offset: Int

    def __init__(
        out self,
        var sort_keys: List[String],
        var descending: List[Bool],
        n: Int,
        var nulls_first: List[Bool] = List[Bool](),
        offset: Int = 0,
    ):
        self.sort_keys = sort_keys^
        self.descending = descending^
        self.n = n
        self.nulls_first = nulls_first^
        self.offset = offset

# =============================================================================
# is_explicit_nulls_first_request -- "did the producer ask for something the
# derived default does NOT already give?"  THE ONE PREDICATE EVERY SPECIALISED
# SORT ROUTE ASKS BEFORE ADMITTING ITSELF.
# =============================================================================

def is_explicit_nulls_first_request(
    imm nulls_first: List[Bool], imm descending: List[Bool]
) -> Bool:
    """True iff `nulls_first` states a placement the engine would NOT derive.

    ★ WHY THIS IS A SHARED FUNCTION AND NOT A `len(...) > 0` AT EACH SITE.
    `SortData.nulls_first` on the LOGICAL plan is ALWAYS full-length — the
    ctor runs it through `logical_plan_variants._resolve_nulls_first`, which
    fills in `derived_nulls_first(descending[i])` when the user said nothing. So a
    producer
    that forwards the plan's list verbatim (forwarding a `List` is cheaper and
    less error-prone than deciding at every site whether to forward) makes
    `SortSinkData.nulls_first`
    NON-EMPTY on every query, including the overwhelming majority that asked
    for nothing. `len(...) > 0` is therefore NOT the question. The question is
    whether the request DIFFERS from `derived_nulls_first(descending[i])` somewhere.

    ⭐ AND IT ASKS THE POLICY FUNCTION RATHER THAN RESTATING THE RULE. "Differs
    from the default" stays true by CONSTRUCTION when the default moves; a
    literal rule here would silently invert which requests count as explicit
    the day the policy changed, so every specialised route would begin
    declining exactly the queries it serves and admitting the ones it declines.

    ⛔ AND THE DIFFERENCE IS LOAD-BEARING, NOT PEDANTIC. Several sort routes
    cannot express a placement at all (the dict-rank counting sort, the
    per-partition parallel sort + k-way merge, the external spilling sorter,
    the row-format spill, the Top-N row-group prune, the bounded AGG-TOPK
    drain): each takes `keys` + `descending` and nothing else. A `len > 0`
    test would make EVERY query decline them and silently delete their entire
    reason to exist; this predicate declines only the queries they would
    answer WRONG.

    Args:
        nulls_first: The requested per-key placement. EMPTY means "derive".
        descending: The per-key directions the default is derived from.

    Returns:
        True iff some key's requested placement differs from the derived default.
    """
    if len(nulls_first) == 0:
        return False
    var n = len(nulls_first)
    if len(descending) < n:
        # A producer bug. Report it as EXPLICIT so the caller's decline /
        # refusal arm runs, rather than reading past the end or answering with
        # the default. The arity is checked and named where the placement is
        # CONSUMED, in the engine (not in this tree).
        return True
    for i in range(n):
        if nulls_first[i] != derived_nulls_first(descending[i]):
            return True
    return False


# =============================================================================
# PartitionBySinkData -- configuration for window function sink
# =============================================================================

struct PartitionBySinkData(Movable):
    """Configuration for a PartitionBy (window function) sink.

    The sink accumulates all input rows, sorts them by (partition_keys ++
    order_keys), then runs the partition-scan operator which adds one
    output column per PartitionExpr.

    Fields:
        partition_keys: Column names to partition by.
        order_keys: Column names defining intra-partition order.
        descending: Per-order-key sort direction.
        partition_exprs: Window function expressions.
        output_schema: Expected output schema (child + window cols).
        nulls_first: Per-order-key NULL placement, or EMPTY for "derive"
            (`derived_nulls_first(descending[i])` per key). Non-empty must
            hold one flag per order key; the window sink refuses any other
            length by name. Partition keys always sort NULLs last.
    """
    var partition_keys: List[String]
    var order_keys: List[String]
    var descending: List[Bool]
    var partition_exprs: List[PartitionExpr]
    var output_schema: Schema
    var nulls_first: List[Bool]

    def __init__(
        out self,
        var partition_keys: List[String],
        var order_keys: List[String],
        var descending: List[Bool],
        var partition_exprs: List[PartitionExpr],
        var output_schema: Schema,
        var nulls_first: List[Bool] = List[Bool](),
    ):
        self.partition_keys = partition_keys^
        self.order_keys = order_keys^
        self.descending = descending^
        self.partition_exprs = partition_exprs^
        self.output_schema = output_schema^
        self.nulls_first = nulls_first^

# =============================================================================
# PartitionTopNSinkData -- configuration for per-partition Top-K sink
# =============================================================================

struct PartitionTopNSinkData(Movable):
    """Configuration for a PartitionTopN sink (per-partition Top-K).

    Mirrors the LogicalPlan PartitionTopNData payload. Output schema =
    the child's columns, plus the INT64 rank column when
    `output_rank_col_name` is set.

    Carries `func` and `over_fetch_k` for the ROW_NUMBER and RANK fast paths.

    CONTRACT for the engine:
      - `func` is the window-function tag from `partition_expr.mojo`
        (`PF_ROW_NUMBER = 0`, `PF_RANK = 1`). The engine's sink
        (`op_window.partition_topn_sink.PartitionTopNSink`, run by
        `pipeline_exec.sink_partition_topn`) keeps, per partition, the rows
        whose ROW_NUMBER (first K rows by sort key; of tied rows the
        earliest) or RANK (1 + count of rows with a strictly better sort key
        in the same partition; ties share rank) is at most `k`. For RANK the
        bounded-heap path uses `over_fetch_k` as the heap capacity, and a
        partition whose full heap still ranks its worst row within `k` is
        recomputed from every row, so every tie within `k` is kept whatever
        `over_fetch_k` is.
      - `over_fetch_k >= k` invariant. Engine code can `assert over_fetch_k >= k`.
      - The optimizer is responsible for setting `over_fetch_k`; engines
        MUST NOT recompute it.

    Fields:
        partition_keys: Column names to partition by. Empty = single
            partition (degenerates to global Top-K).
        sort_keys: Column names defining intra-partition order.
        descending: Per-sort-key sort direction. Same length as sort_keys.
        k: Number of rows per partition to keep. Must be >= 0.
        func: Window function discriminant (PF_ROW_NUMBER=0, PF_RANK=1).
            Default 0 (PF_ROW_NUMBER).
        over_fetch_k: Internal heap capacity per partition. >= k. For
            PF_ROW_NUMBER, equals k. For PF_RANK, k + tie-buffer epsilon.
            -1 sentinel at construction = auto-derive from k.
        output_rank_col_name: When `Some(name)`,
            the kernel emits an Int64 column with that name carrying the
            rank value per surviving row (so downstream operators can
            resolve the rk/rn reference). When `None` (default), the
            kernel emits the child schema only.
        output_schema: Expected output schema. When `output_rank_col_name`
            is Some, this schema MUST already include the trailing rank
            column (the LogicalPlan factory builds it that way).
    """
    var partition_keys: List[String]
    var sort_keys: List[String]
    var descending: List[Bool]
    var k: Int
    var func: UInt8
    var over_fetch_k: Int
    var output_rank_col_name: Optional[String]
    var output_schema: Schema

    def __init__(
        out self,
        var partition_keys: List[String],
        var sort_keys: List[String],
        var descending: List[Bool],
        k: Int,
        var output_schema: Schema,
        func: UInt8 = 0,  # PF_ROW_NUMBER default
        over_fetch_k: Int = -1,  # -1 sentinel = auto-derive from k
        var output_rank_col_name: Optional[String] = None,
    ):
        self.partition_keys = partition_keys^
        self.sort_keys = sort_keys^
        self.descending = descending^
        self.k = k
        self.func = func
        if over_fetch_k < 0:
            self.over_fetch_k = k
        else:
            self.over_fetch_k = over_fetch_k
        self.output_rank_col_name = output_rank_col_name^
        self.output_schema = output_schema^

# =============================================================================
# AsofJoinSinkData -- configuration for ASOF-join sink
# =============================================================================

struct AsofJoinSinkData(Movable):
    """Configuration for an ASOF-join sink (time-series left join).

    Mirrors the LogicalPlan AsofJoinData payload one-for-one plus the
    resolved output schema (left cols as-is + right cols force-nullable
    with `_right` suffix on name collisions).

    The engine's merge kernel (not in this tree) is a two-cursor walker + a
    best-match search generic over (strategy, dtype) + interleave
    materialization over batch-ingested sides (both sides loaded, sorted,
    walked).

    Fields:
        left_keys / right_keys: Parallel equi-key column names (BY).
        left_asof / right_asof: ASOF column names on each side.
        strategy: ASOF_BACKWARD / FORWARD / NEAREST.
        tolerance: AsofTolerance (opaque -- tag NONE/INT64/FLOAT64).
        left_sort_keys / left_sort_desc: Pre-sort hint (empty = sort).
        right_sort_keys / right_sort_desc: Symmetric pre-sort hint.
        output_schema: Expected output (= left cols + right cols with
            nullability forced True on right side).
    """
    var left_keys: List[String]
    var right_keys: List[String]
    var left_asof: String
    var right_asof: String
    var strategy: UInt8
    var tolerance: AsofTolerance
    var left_sort_keys: List[String]
    var left_sort_desc: List[Bool]
    var right_sort_keys: List[String]
    var right_sort_desc: List[Bool]
    var output_schema: Schema
    # Resolved once at plan-compile time (inverse of
    # ArrowType.from_dtype over the output_schema lookup for `left_asof`).
    # The engine's kernel dispatch (not in this tree) reads this to pick the
    # correct (strategy, dtype) monomorph without re-inspecting schemas.
    var asof_dtype: DType
    # seg_id of the right-side materialization segment. The
    # executor's SINK_ASOF_JOIN branch pulls the right RecordBatch back
    # from that segment's sink output at materialize time (batch-ingest
    # topology -- both sides land as single pre-materialized batches, then
    # the walker runs once). The -1 sentinel produces a clear failure.
    var right_seg_id: Int

    def __init__(
        out self,
        var left_keys: List[String],
        var right_keys: List[String],
        var left_asof: String,
        var right_asof: String,
        strategy: UInt8,
        tolerance: AsofTolerance,
        var left_sort_keys: List[String],
        var left_sort_desc: List[Bool],
        var right_sort_keys: List[String],
        var right_sort_desc: List[Bool],
        var output_schema: Schema,
        asof_dtype: DType = DType.int64,
        right_seg_id: Int = -1,
    ):
        self.left_keys = left_keys^
        self.right_keys = right_keys^
        self.left_asof = left_asof^
        self.right_asof = right_asof^
        self.strategy = strategy
        self.tolerance = tolerance
        self.left_sort_keys = left_sort_keys^
        self.left_sort_desc = left_sort_desc^
        self.right_sort_keys = right_sort_keys^
        self.right_sort_desc = right_sort_desc^
        self.output_schema = output_schema^
        self.asof_dtype = asof_dtype
        self.right_seg_id = right_seg_id

# =============================================================================
# HashBuildSinkData -- configuration for hash join build sink
# =============================================================================

struct HashBuildSinkData(Movable):
    """Configuration for a hash join build-side sink.

    Fields:
        key_names: Column names of the join keys on the build side. For
            single-key joins this list has length 1; for multi-key joins
            it carries the parallel build-side
            key columns aligned by position with the probe-side key columns.
        join_type: Join type constant (JOIN_INNER, JOIN_LEFT, etc.).
    """
    var key_names: List[String]
    var join_type: UInt8

    def __init__(out self, var key_names: List[String], join_type: UInt8):
        self.key_names = key_names^
        self.join_type = join_type

    @always_inline
    def primary_key_name(self) -> String:
        """First (or only) key name -- shorthand for legacy single-key paths."""
        return self.key_names[0]

# =============================================================================
# SMJBuildSinkData -- configuration for sort-merge join build sink
# =============================================================================
#
# SMJ build is strictly simpler than hash build: no hash table is constructed.
# The sink is an identity pass -- it accumulates the build-side RecordBatch so
# the probe can read it back from that sink's output and run the sort-merge
# kernel directly. Carrying a distinct tag (SINK_SMJ_BUILD) instead of reusing
# SINK_HASH_BUILD eliminates a wasted hash-build sink construction and
# naturally prevents the engine's streaming-join fusion
# fast path (it gates on SINK_HASH_BUILD) from firing
# on SMJ pipelines -- SMJ probe cannot fuse with a streaming build.
# =============================================================================


struct SMJBuildSinkData(Movable):
    """Configuration for a sort-merge join build-side sink.

    Fields:
        key_names: Build-side key column names. For single-key SMJ this
            list has length 1; multi-key SMJ is not yet supported and the
            plan compiler (not in this tree) downgrades multi-key
            SORT_MERGE hints to HASH.
        join_type: Join type constant (JOIN_INNER; LEFT/RIGHT/FULL SMJ are
            not yet supported).
    """
    var key_names: List[String]
    var join_type: UInt8

    def __init__(out self, var key_names: List[String], join_type: UInt8):
        self.key_names = key_names^
        self.join_type = join_type

    @always_inline
    def primary_key_name(self) -> String:
        """First (or only) key name -- shorthand for legacy single-key paths."""
        return self.key_names[0]
