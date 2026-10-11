# =============================================================================
# physical_plan -- PhysicalPlan IR (Source -> [Operators] -> Sink) + version
# =============================================================================
#
# This module is the home of the in-process PhysicalPlan IR shared between
# the plan compiler (emitter) and the engine (consumer); neither is in this
# tree. These structs are INERT data — no Arc, OwnedPointer, ArcPointer,
# UnsafePointer, Atomic, callbacks, closures, or trait-object fields. The inert
# constraint is enforced by a repository structural lint and the schema-drift
# canary `PHYSICAL_PLAN_IR_VERSION` defined below.
# =============================================================================

# ⚠ NO `from std.testing import assert_true` HERE. This is an INERT-IR module,
# and the version door raises an `Error` whose message it builds ONLY on the
# failing path -- `assert_true` evaluates its message eagerly, and the door
# is written to run on every cut of every query.

from komira_plan_expr.expr import Expr
from komira_plan_expr.agg_expr import AggExpr
from komira_plan_ir.logical_plan import ExprArray, AggExprArray, JOIN_ALGO_HASH, AsofTolerance
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.partition_pred_pod import PartitionPredicatePod
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod
from komira_plan_expr.payload_narrow import PayloadNarrowSpec
from komira_plan_expr.null_order_policy import derived_nulls_first
from komira_arrow.schema import RecordBatch, Schema, Field
from komira_collections.slab import Slab


# =============================================================================
# IR version constant + bump policy
# =============================================================================
#
# Bump policy:
#   - Any added field to any IR variant -> bump.
#   - Any removed field from any IR variant -> bump.
#   - Any type change to a field (e.g. Int32 -> Int64,
#     String -> ScalarValue) -> bump.
#   - Any semantic change to a field's meaning (e.g. "rows" -> "bytes",
#     unit change, sentinel-value change) -> bump.
#   - Any new variant struct (new sink, new operator) -> bump.
#   - A change that makes routing depend on a previously-inert field -> bump
#     (a compatibility marker even with no layout change).
#   - Pure renames where new and old names mean the same thing -> NO bump
#     (but update every caller in the same commit).
#
# Enforcement: a code-review responsibility AND a repository lint that fires
# when this file's variant struct bodies change without a bump in the same
# diff. The structural inert-field lint is separate.
#
# Notable versions:
#   11: `row_mode` — the 3-valued per-segment row-mode classifier
#       (`ROW_MODE_*` below).
#   12: `SegmentDescPod.ir_version` — THE VERSION DOOR (see the door below).
#       The field is ALSO the enforcement mechanism, so forgetting a bump makes
#       a real check wrong rather than only a marker stale.
#   13: `SourceSpecPod.parquet_spec_is_total` — a DERIVED, FAIL-CLOSED Bool
#       recording whether the three parquet fields beside it REPRODUCE the
#       scan they were minted from (see its docstring).
#   Retired `MorselOp` tag values (4-13) are not reused.

comptime PHYSICAL_PLAN_IR_VERSION: Int = 13


# =============================================================================
# row_mode sentinels
# =============================================================================
#
# 3-valued per-segment row-mode classifier (inert UInt8):
#
#   - COLUMNAR: column-oriented source (Parquet/Arrow/ORC), no
#               keep_row-only UDFs.
#   - ROW_UDF:  CSV/NDJSON source OR a segment carrying a keep_row-only
#               UDF (no eval[W] override).
#   - BATCH_UDF: segment carries a keep_batch/map_batch/update_batch UDF.
#
# The typed `Stage` reads `row_mode` COMPTIME from its slot conformers
# (no runtime branch on the perf ceiling); the runtime UInt8 bit is the
# untyped-path mechanism only. The derivation is whole-segment — NOT
# per-MorselOp.
comptime ROW_MODE_COLUMNAR: UInt8 = 0
comptime ROW_MODE_ROW_UDF: UInt8 = 1
comptime ROW_MODE_BATCH_UDF: UInt8 = 2

# Maximum depth of a fused operator chain. Validated at depth 15 by a
# depth-ceiling microbench (depth 15 costs 1.45x depth 7, under the 2x
# ceiling); flat parameter chains stay green to depth 20, so the cap leaves a
# 5-deep margin against trait-method body complexity.
comptime MAX_FUSION_DEPTH: Int = 15


# =============================================================================
# THE VERSION DOOR — the one check that stands between a layout skew and
# tcmalloc corruption with no diagnostic
# =============================================================================
#
# The door verifies `ir_version == PHYSICAL_PLAN_IR_VERSION` for every
# segment at the engine's plan-entry chokepoint.
#
# ⛔ WHY IT IS NOT OPTIONAL. When the optimizer and the engine live in
# SEPARATE `.so`s they exchange `SegmentDescPod` as a NATIVE VALUE across an
# `@extern` pair — a LINKAGE boundary, not an address-space one, so no
# serialization step exists to notice a disagreement. The ABI contract is
# UNCHECKED by the toolchain, and two `.so`s built from different revisions of
# THIS FILE were measured to produce tcmalloc corruption WITH NO DIAGNOSTIC.
# That is the failure this door converts into a refusal that says what
# happened.
#
# ⚠ THE DOOR ONLY WORKS IF THE FIELD IS STAMPED BY THE PRODUCER. It is: the
# default on `SegmentDescPod.__init__` is this very constant, so a pod built by
# a `.so` compiled against IR vN carries N — and the consumer, compiled against
# IR vM, compares against M. A skew is therefore visible from the FIRST WORD of
# the struct (`ir_version` is field #0 on purpose) rather than from whatever
# garbage a shifted field offset produces.


comptime PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE: StaticString = (
    "PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE"
)
"""The token this door puts in its zero-segment refusal.

⚠ IT IS A `comptime` CONSTANT SO A CLASSIFIER CAN IMPORT IT RATHER THAN
RE-SPELL IT. The `@extern` boundary (in the SDK; not in this tree)
has to tell a door refusal apart from a pass refusal -- a door refusal means the
PRODUCER emitted a physical plan this binary cannot read, which is not the
caller's bug and is not fixed by resubmitting -- and a second spelling on the
classifier's side is exactly how the two silently stop matching. Same idiom, and
the same reason, as the purity gate's three tokens and `SCAN_BINDING_*`."""

comptime PHYSICAL_PLAN_IR_VERSION_MISMATCH: StaticString = (
    "PHYSICAL_PLAN_IR_VERSION_MISMATCH"
)
"""The token this door puts in its version-skew refusal. See the note above for
why it is a constant rather than a literal at the raise site."""


def assert_physical_plan_ir_version_compatible(
    imm segments: List[SegmentDescPod],
) raises:
    """Verify the physical plan's IR contract matches the constant baked into
    THIS binary. Raises on the first mismatch, naming the segment and both
    versions.

    Written to be called ONCE per cut at the plan-entry chokepoint
    (`segment_cutter.cut_and_admit`). That cutter is not in this tree, and
    nothing here calls this function except its test. It takes the whole
    segment list rather than one segment so the chokepoint stays a single call
    site: a per-segment call scattered through a cutter is the shape that gets
    partially deleted later, leaving some segments unchecked and the gate still
    green.

    ⚠ AN EMPTY PLAN IS NOT CHECKABLE AND IS NOT A PASS. Zero segments means the
    caller has nothing whose version could be compared, and a door that returns
    OK over an empty list is indistinguishable from a door that was never
    called — a vacuous gate. It
    raises.
    """
    if len(segments) == 0:
        raise Error(
            PHYSICAL_PLAN_IR_VERSION_UNCHECKABLE,
            ": asked to verify the IR",
            " version of a plan with ZERO segments. Nothing was compared, so",
            " this is a REFUSAL, not a pass -- an empty plan reaching the",
            " version door means its producer emitted no segments.",
        )
    for i in range(len(segments)):
        var seen = segments[i].ir_version
        if seen == PHYSICAL_PLAN_IR_VERSION:
            continue
        # ⚠ THE MESSAGE IS BUILT ONLY ON THE FAILING PATH. This door is
        # written to run on EVERY cut of EVERY query; N message constructions
        # per plan, for a check that passes every time, is real work on the
        # plan path.
        raise Error(
            PHYSICAL_PLAN_IR_VERSION_MISMATCH,
            ": segment seg_id=",
            segments[i].seg_id,
            " (list index ",
            i,
            ") was emitted at PhysicalPlan IR v",
            seen,
            " but this binary expects v",
            PHYSICAL_PLAN_IR_VERSION,
            ". Either the two packages are built from different revisions",
            " (rebuild both), or a field was added/removed/retyped in",
            " komira_physical_plan/physical_plan.mojo without bumping",
            " PHYSICAL_PLAN_IR_VERSION in the same change. Do NOT silence",
            " this: the struct layouts have diverged, and reading a",
            " SegmentDescPod through the wrong layout was measured to",
            " corrupt tcmalloc with no other symptom.",
        )


# =============================================================================
# Tag constants for tagged unions
# =============================================================================

# Source tags (`SegmentDescPod.source_kind`)
comptime SOURCE_PARQUET: UInt8 = 0     # Read from Parquet file
comptime SOURCE_BATCH: UInt8 = 1       # Read from in-memory RecordBatch
comptime SOURCE_SINK_OUTPUT: UInt8 = 2 # Read from a completed sink's output
comptime SOURCE_CONCAT: UInt8 = 3      # Concatenate N completed sinks' outputs
                                       # (the physical form of PLAN_UNION)

# MorselOp tags
comptime OP_FILTER: UInt8 = 0          # Predicate filter (SV-based)
comptime OP_PROJECT: UInt8 = 1         # Column projection / expression eval
comptime OP_LIMIT: UInt8 = 2           # Row count limit
comptime OP_JOIN_PROBE: UInt8 = 3      # Hash join probe (streaming)
# MorselOp tag values 4-13 are retired and must not be reused; the next free
# tag id is 14.

# Sink tags (`SegmentDescPod.sink_kind`)
comptime SINK_AGG: UInt8 = 0           # Hash aggregation
comptime SINK_SORT: UInt8 = 1          # Full sort
comptime SINK_TOPN: UInt8 = 2          # TopN (fused sort + limit)
comptime SINK_COLLECT: UInt8 = 3       # Simple row collection
comptime SINK_HASH_BUILD: UInt8 = 4    # Hash join build side
comptime SINK_PARTITION_BY: UInt8 = 5  # PartitionBy (window functions)
comptime SINK_PARTITION_TOPN: UInt8 = 6  # PartitionTopN (per-partition Top-K)
comptime SINK_SMJ_BUILD: UInt8 = 7     # Sort-merge join build side (no HT construction)
comptime SINK_ASOF_JOIN: UInt8 = 8     # ASOF left-join (time-series match)
comptime SINK_JOIN_PROBE: UInt8 = 9    # Hash-join PROBE side (streams fact morsels through
                                       # a consumed build HT -> joined output;
                                       # a run-thunk registry key)


# =============================================================================
# ParquetSourceData -- configuration for Parquet morsel source
# =============================================================================

@fieldwise_init
struct ParquetRowWindow(Copyable, Movable, ImplicitlyCopyable):
    """Targeted row-slice window over an ORDERED parquet table.

    A `(offset, length)` absolute row range over the table's rows in physical
    (file-major, row-group-order) sequence. Carried on `ParquetSourceData` ONLY
    for a scan-only / projection-only `df.slice(offset, length)` pushdown (the
    child chain must not change cardinality/order — no filter / breaker). The
    collect leaf (in the engine; not in this tree) resolves this window
    against the footer row-group prefix sums into a targeted flat-RG index
    range so the source decodes ONLY the row groups that overlap the window,
    then trims the concatenated result to exactly `[offset, offset + length)`.

    Fields:
        offset: absolute row offset over the ordered table (>= 0).
        length: number of rows to keep (>= 0).
    """

    var offset: Int
    var length: Int


struct ParquetSourceData(Movable):
    """Configuration for a Parquet file morsel source.

    Fields:
        file_path: Path to the Parquet file OR a Hive base dir/glob.
        projection: Optional list of column names to read. None = all columns.
        pushed_filter: Optional predicate for scan-level pushdown (Tier-2 DATA
            residual for a Hive source).
        hive_partition_cols: the partition-column schema
            (name+type) for a dir-scanning Hive source. EMPTY for non-Hive
            (single-file / flat multi-file) sources.
        hive_predicate: the Tier-1 partition-prune POD. `is Some`
            is the dir-scan-Hive discriminant the materialize site branches on
            (Some -> PrunedHiveDiscovery; None -> the EagerGlob path).
            `Some(empty())` is the un-filtered Hive read (surfaces partition
            cols, prunes nothing).
        fs_descriptor: the per-source FS IDENTITY POD (scheme +
            bucket/container + node_id): the exact source the scan reads,
            its scheme the code komira_source_url maps the source URL's
            prefix to. Defaulted to `FsDescriptorPod.local()` (scheme=FILE,
            node_id=-1) — the local default. Core names NO FS type here —
            only the identity POD; the file system that reads the source is
            the one whose `SCHEME` is this scheme. See
            `komira_plan_expr/fs_descriptor_pod.mojo`.
    """
    var file_path: String
    var projection: Optional[List[String]]
    var pushed_filter: Optional[Expr]
    # --- Hive dir-scan fields — both defaulted (List[Field]() / None). ---
    var hive_partition_cols: List[Field]
    var hive_predicate: Optional[PartitionPredicatePod]
    # --- Defaulted to FsDescriptorPod.local() (local default). Names the
    #     source; the plan carries no live file system. ---
    var fs_descriptor: FsDescriptorPod
    # --- Defaulted False. ONLY the engine's col-untyped agg-source
    #     path (not in this tree) sets it True, which
    #     turns on `hooks.set_dict_preservation(True)` inside
    #     the engine's parquet collect so the numeric dict arms of
    #     the page decoder emit NUMERIC DICTIONARY Columns. Scoped to the
    #     agg source so scan-collect / to_parquet (which can't consume a numeric
    #     DICTIONARY column) stay on the flat path. ---
    var preserve_numeric_dict: Bool
    # --- The EXPLICIT enumerated file list for a
    #     flat multi-file OR eager-Hive-partitioned read. DEFAULTED EMPTY
    #     (empty ⇒ discovery keys off `file_path` alone). When NON-empty the collect
    #     leaf (in the engine; not in this tree) builds discovery from THIS list
    #     via `EagerGlobDiscovery.open_paths` (flat, when `hive_partition_cols` is
    #     empty) or `PrunedHiveDiscovery.from_listing` (partition-aware, when
    #     `hive_partition_cols` is non-empty), rather than `DISC.open(fs,
    #     file_path)`. Without it an eager multi-file / partitioned read would
    #     silently read only `file_path` (= paths[0]). The
    #     LAZY dir-scan Hive path (`hive_predicate is Some`) keeps
    #     using `file_path` as the base dir; `explicit_paths` is the EAGER shape.
    #     `file_path` stays populated (= paths[0]) for the schema-seed footer read
    #     + EXPLAIN. ---
    var explicit_paths: List[String]
    # --- The targeted
    #     row-slice window. DEFAULTED None (no window ⇒ decode all row
    #     groups). Set ONLY by the
    #     SDK `df.slice(offset, length)` pushdown when the child chain is
    #     scan-only / projection-only over a deterministically-enumerable parquet
    #     source (single file OR flat explicit multi-file). When `is Some`, the
    #     collect leaf resolves it against footer RG prefix sums into a targeted
    #     flat-RG index range (source decodes ONLY those RGs) and trims the
    #     concatenated result to exactly `[offset, offset + length)`. A slice over
    #     a filter / sort / agg / Hive-dir-scan is NOT eligible (the SDK keeps
    #     those on the sink-absorption fallback). ---
    var row_window: Optional[ParquetRowWindow]
    # --- The STRING dict-preservation ARM
    #     selector. DEFAULTED **True**: the engine's typed parquet stage (not
    #     in this tree) turns `hooks.set_dict_preservation(True)` on for a
    #     HASH_AGG breaker, which makes the page decoder emit DICTIONARY (codes
    #     + per-RG dict page) Columns for STRING group keys instead of a dense
    #     StringArray built from the dictionary.
    #
    #     WHY A FIELD AND NOT AN ENV PROBE. The DENSE-STRING arm must stay
    #     reachable through the real engine so the end-to-end parquet-decode
    #     -> HASH_AGG differential exists. The engine's session knob (not in
    #     this tree) is stamped onto
    #     this POD at the typed-grouped-agg dispatch sites and the
    #     materialize site consults the POD — production API, not an
    #     environment variable.
    #
    #     SCOPE. Read ONLY inside the `B.tag() == BREAKER_HASH_AGG` comptime
    #     scope of the engine's typed parquet stage. That scope gate is
    #     load-bearing (a non-HASH_AGG breaker handed a DICTIONARY column
    #     tcmalloc-crashes) — this field can only ever move a
    #     HASH_AGG string group key BACK onto the dense-STRING decode that every
    #     other breaker already takes, never the other way. ---
    var preserve_string_dict: Bool
    # --- The per-column integral-narrowing
    #     instructions carried down from `ScanData.payload_narrow` by the
    #     engine's join executor (not in this tree). EMPTY at construction at
    #     every site (it is deliberately NOT a ctor argument — see the same note
    #     on `ScanData.payload_narrow`).
    #
    #     ⚠ IT IS ADVISORY, AND EXACTLY ONE LEAF HONOURS IT.
    #     The engine's parquet join materializer narrows the BUILD-side
    #     resident batch on the way in and widens the joined batch on the way
    #     out, so the narrow representation is created and destroyed inside one
    #     function. Any other consumer of a `ParquetSourceData` carrying this
    #     list IGNORES it and reads the column at its declared width — which is
    #     correct, because nothing has narrowed it. A half-applied narrowing (a
    #     reader that subtracts `base` without a writer that adds it back, or
    #     the reverse) is the one wrong-answer shape here, and "ignore it" is
    #     the only disposition that cannot produce one. ---
    var payload_narrow: List[PayloadNarrowSpec]

    def __init__(
        out self,
        file_path: String,
        var projection: Optional[List[String]],
        var pushed_filter: Optional[Expr],
        var hive_partition_cols: List[Field] = List[Field](),
        var hive_predicate: Optional[PartitionPredicatePod] = None,
        var fs_descriptor: FsDescriptorPod = FsDescriptorPod.local(),
        preserve_numeric_dict: Bool = False,
        var explicit_paths: List[String] = List[String](),
        var row_window: Optional[ParquetRowWindow] = None,
        preserve_string_dict: Bool = True,
    ):
        self.file_path = file_path
        self.projection = projection^
        self.pushed_filter = pushed_filter^
        self.hive_partition_cols = hive_partition_cols^
        self.hive_predicate = hive_predicate^
        self.fs_descriptor = fs_descriptor^
        self.preserve_numeric_dict = preserve_numeric_dict
        self.explicit_paths = explicit_paths^
        self.row_window = row_window^
        self.preserve_string_dict = preserve_string_dict
        # Payload narrowing: always EMPTY at construction. See the field comment.
        self.payload_narrow = List[PayloadNarrowSpec]()

# =============================================================================
# The descriptor contract
# =============================================================================
#
# `SegmentDescPod` + `SourceSpecPod` below are the live descriptor contract.
# The sink there is a TAG TRIPLE precisely so it is never a sink struct
# carried by value. `ParquetSourceData`, `MorselOp`, and every `*SinkData`
# struct (`AggSinkData`, `SortSinkData`, `TopNSinkData`, `PartitionBySinkData`,
# `PartitionTopNSinkData`, `AsofJoinSinkData`, `HashBuildSinkData`,
# `SMJBuildSinkData`) each have independent consumers in the engine's
# operators, which are not in this tree.
# =============================================================================

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
            sink via `choose_strategy` (`komira_agg_api`). The compiler and
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

    def __init__(
        out self,
        var sort_keys: List[String],
        var descending: List[Bool],
        n: Int,
        var nulls_first: List[Bool] = List[Bool](),
    ):
        self.sort_keys = sort_keys^
        self.descending = descending^
        self.n = n
        self.nulls_first = nulls_first^

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
    """
    var partition_keys: List[String]
    var order_keys: List[String]
    var descending: List[Bool]
    var partition_exprs: List[PartitionExpr]
    var output_schema: Schema

    def __init__(
        out self,
        var partition_keys: List[String],
        var order_keys: List[String],
        var descending: List[Bool],
        var partition_exprs: List[PartitionExpr],
        var output_schema: Schema,
    ):
        self.partition_keys = partition_keys^
        self.order_keys = order_keys^
        self.descending = descending^
        self.partition_exprs = partition_exprs^
        self.output_schema = output_schema^

# =============================================================================
# PartitionTopNSinkData -- configuration for per-partition Top-K sink
# =============================================================================

struct PartitionTopNSinkData(Movable):
    """Configuration for a PartitionTopN sink (per-partition Top-K).

    Mirrors the LogicalPlan PartitionTopNData payload. Output schema =
    child schema (no new columns; the sink selects existing rows).

    Carries `func` and `over_fetch_k` for the ROW_NUMBER and RANK fast paths.

    CONTRACT for the engine:
      - `func` is the window-function tag from `partition_expr.mojo`
        (`PF_ROW_NUMBER = 0`, `PF_RANK = 1`). The engine's PartitionTopN sink
        (not in this tree) implements ROW_NUMBER semantics (first K rows by
        sort key per partition, no tie handling). For RANK, the engine must:
          1. Use `over_fetch_k` as the heap capacity (NOT `k`).
          2. After collecting the top `over_fetch_k` rows by sort key,
             compute a rank for each row (1 + count of rows with strictly
             better sort key in the same partition; ties share rank).
          3. Filter to rows with `rank <= k`.
        For 10K rows/partition with a Float64 score,
        tie probability ≈ 10K × 2^-52 → effectively zero, so the
        over-fetch buffer of K+16 covers all real-world inputs.
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

# =============================================================================
# MorselOp -- tagged union for streaming operators
# =============================================================================

struct MorselOp(Movable):
    """Tagged union for streaming operators within a segment.

    Streaming operators transform morsels in-place without breaking the pipeline.
    Exactly one variant is active, determined by `tag`.

    Tags:
        OP_FILTER: Evaluate predicate, update selection vector.
        OP_PROJECT: Evaluate expressions, replace batch columns.
        OP_LIMIT: Enforce row count limit (with atomic counter for parallel).
        OP_JOIN_PROBE: Probe a hash table built by a completed build segment.

    Late-materialization fields (OP_JOIN_PROBE only):
        probe_output_cols: Optional list of join-output column names to keep.
            When set, the join probe materializes only these columns (from the
            combined left+right output schema). Unused columns are skipped
            entirely -- a massive win for multi-join queries where downstream
            operators only reference a small subset. When None, all columns
            are materialized (legacy behavior).
    """
    var tag: UInt8
    var filter_predicate: Optional[Expr]
    var project_exprs: Optional[ExprArray]
    var project_names: Optional[List[String]]
    # OP_PROJECT ONLY -- True iff this project is a PURE REORDER of its input:
    # every output expr is a bare col-ref, every output name EQUALS the column it
    # references (no rename), no column is dropped and none is duplicated. Such an
    # op changes the column ORDER and NOTHING ELSE, so a consumer that resolves
    # its inputs BY NAME may see through it. Derived at cut time from the two
    # schemas by the segment cutter (not in this tree), never asserted by a
    # producer -- the property is a fact about the node, so deriving it covers
    # whichever pass emits the next one. Default False: absent proof, an
    # OP_PROJECT is opaque.
    var project_reorders_only: Bool
    var limit_count: Int       # for OP_LIMIT; -1 when unused
    var probe_build_seg: Int   # segment ID of build side for OP_JOIN_PROBE; -1 when unused
    var probe_left_keys: List[String]  # probe-side key column names for OP_JOIN_PROBE (len >= 1)
    var probe_right_keys: List[String] # build-side key column names for OP_JOIN_PROBE (len >= 1)
    var probe_join_type: UInt8 # join type for OP_JOIN_PROBE
    # Physical-algorithm selector for OP_JOIN_PROBE. Orthogonal to probe_join_type;
    # the plan compiler resolves JOIN_ALGO_AUTO to a concrete algo (HASH today,
    # cost model later), and the engine's join probe dispatches to the SMJ kernel
    # when probe_algo == JOIN_ALGO_SORT_MERGE. Neither is in this tree.
    var probe_algo: UInt8
    var probe_output_cols: Optional[List[String]]  # late-materialization projection (OP_JOIN_PROBE)
    # Non-equi / range / complex join residual predicate (OP_JOIN_PROBE).
    # Set by the plan compiler (not in this tree) from `JoinData.residual`
    # after the `join_predicate_decompose` pass has lifted every `Expr.left ==
    # Expr.right` conjunct into `probe_left_keys`/`probe_right_keys`. The
    # residual Expr is already rewritten to plain (COL_SIDE_NONE) col-refs over
    # the joined-row schema (left cols [0..L), right cols [L..L+R) with
    # `_right` collision rename) so the engine can evaluate it directly against
    # the assembled matched-pair batch. When set, the engine's join probe takes
    # its residual path. `Expr` is inert IR data (same as `filter_predicate`),
    # so this field keeps the IR inert.
    var probe_residual: Optional[Expr]

    @staticmethod
    def filter(var predicate: Expr) -> MorselOp:
        """Create a filter operator."""
        var op = MorselOp(tag=OP_FILTER)
        op.filter_predicate = predicate^
        return op^

    @staticmethod
    def project(
        var exprs: ExprArray,
        var names: List[String],
        reorders_only: Bool = False,
    ) -> MorselOp:
        """Create a project operator.

        Args:
            exprs: Expressions to evaluate (one per output column).
            names: Output column names.
            reorders_only: True ONLY when the caller has PROVEN this project is a
                pure column reorder of its input (see `project_reorders_only`).
                Defaults to False so every existing caller stays opaque.
        """
        var op = MorselOp(tag=OP_PROJECT)
        op.project_exprs = exprs^
        op.project_names = names^
        op.project_reorders_only = reorders_only
        return op^

    @staticmethod
    def limit(n: Int) -> MorselOp:
        """Create a limit operator."""
        var op = MorselOp(tag=OP_LIMIT)
        op.limit_count = n
        return op^

    @staticmethod
    def join_probe(
        build_segment_id: Int,
        var left_keys: List[String],
        var right_keys: List[String],
        join_type: UInt8,
        probe_algo: UInt8 = JOIN_ALGO_HASH,
    ) -> MorselOp:
        """Create a join probe operator (full materialization).

        Args:
            build_segment_id: Segment ID of the completed build side.
            left_keys: Probe-side join key column names (len >= 1).
            right_keys: Build-side join key column names (len >= 1).
            join_type: Semantic join type (INNER/LEFT/SEMI/ANTI/...).
            probe_algo: Physical algorithm (JOIN_ALGO_HASH / JOIN_ALGO_SORT_MERGE).
        """
        var op = MorselOp(tag=OP_JOIN_PROBE)
        op.probe_build_seg = build_segment_id
        op.probe_left_keys = left_keys^
        op.probe_right_keys = right_keys^
        op.probe_join_type = join_type
        op.probe_algo = probe_algo
        return op^

    @staticmethod
    def join_probe_projected(
        build_segment_id: Int,
        var left_keys: List[String],
        var right_keys: List[String],
        join_type: UInt8,
        var output_cols: List[String],
        probe_algo: UInt8 = JOIN_ALGO_HASH,
    ) -> MorselOp:
        """Create a join probe operator with late-materialization projection.

        Args:
            build_segment_id: Segment ID of the completed build side.
            left_keys: Probe-side join key column names (len >= 1).
            right_keys: Build-side join key column names (len >= 1).
            join_type: Semantic join type.
            output_cols: Names of columns to materialize from the combined
                join output schema. Columns NOT in this list are skipped.
            probe_algo: Physical algorithm (JOIN_ALGO_HASH / JOIN_ALGO_SORT_MERGE).
        """
        var op = MorselOp(tag=OP_JOIN_PROBE)
        op.probe_build_seg = build_segment_id
        op.probe_left_keys = left_keys^
        op.probe_right_keys = right_keys^
        op.probe_join_type = join_type
        op.probe_algo = probe_algo
        op.probe_output_cols = output_cols^
        return op^

    @staticmethod
    def join_probe_with_residual(
        build_segment_id: Int,
        var left_keys: List[String],
        var right_keys: List[String],
        join_type: UInt8,
        var residual: Expr,
        var output_cols: Optional[List[String]],
        probe_algo: UInt8 = JOIN_ALGO_HASH,
    ) -> MorselOp:
        """Create a join probe operator carrying a non-equi / range / complex
        residual predicate.

        `left_keys` / `right_keys` are the equi-keys lifted by the
        `join_predicate_decompose` pass (may be empty for a pure-range NLJ);
        `residual` is the surviving condition rewritten to plain col-refs over
        the joined-row schema. `output_cols` carries the late-materialization
        projection (or None to materialize every column).
        """
        var op = MorselOp(tag=OP_JOIN_PROBE)
        op.probe_build_seg = build_segment_id
        op.probe_left_keys = left_keys^
        op.probe_right_keys = right_keys^
        op.probe_join_type = join_type
        op.probe_algo = probe_algo
        op.probe_output_cols = output_cols^
        op.probe_residual = residual^
        return op^

    def __init__(out self, tag: UInt8):
        self.tag = tag
        self.filter_predicate = None
        self.project_exprs = None
        self.project_names = None
        self.project_reorders_only = False
        self.limit_count = -1
        self.probe_build_seg = -1
        self.probe_left_keys = List[String]()
        self.probe_right_keys = List[String]()
        self.probe_join_type = 0
        self.probe_algo = JOIN_ALGO_HASH
        self.probe_output_cols = None
        self.probe_residual = None

# =============================================================================
# The descriptor contract — SegmentDescPod + SourceSpecPod (inert POD)
# =============================================================================
#
# THE CONTRACT half of the shape-free executor. A query is a runtime walk that
# fills POD descriptors; every runtime (the wave-fold sequencer, an event-DAG
# scheduler) consumes the SAME `List[SegmentDescPod]`.
# Genericity lives in RUNTIME DATA — never the type system — so the elaboration
# budget stays `O(op-kinds x dtypes)` (the registry), paid ONCE, query-independent.
#
# WHY THESE LIVE HERE (the two-layer split): the inert-IR lint
# bans pointer/thunk/operator-by-value FIELDS in this file. A descriptor that
# carried kernel thunks or a state `OwnedPointer` COULD NOT be inert IR. So the
# descriptor is pure POD here (passes the lint); the fn-ptr kernel-thunk table +
# the erased state live in a runtime module of the engine (not in this tree)
# that this file never imports. The sink is a TAG TRIPLE (sink_kind /
# sink_key_dtype / sink_orientation), NEVER a sink struct by value — a
# god-struct line. Params are erased behind `sink_param_id` so the descriptor
# is CONSTANT-WIDTH across the sink zoo.
#
# SAFETY: the driver holds `List[SegmentDescPod]`, NEVER a byte-slab of
# segments — `SegmentDescPod` and `MorselOp` carry `List`/`String` inner fields,
# so a byte-arena `Slab` of them would reinterpret stale bytes across a
# destroy-recreate cycle. The `ops: Slab[MorselOp]` FIELD is a typed Slab held
# by a driver-owned struct, not a wildcard-cast byte-slab element.

# ---- E1..E5 edge tags (the breaker/barrier relaxation taxonomy), one UInt8 per
#      incoming edge, PARALLEL to `SegmentDescPod.deps`. A closed 5-value set = ONE
#      elaboration; the runtime reads a tag to pick a policy, never a per-edge
#      monomorph.
comptime EDGE_E1_MORSEL_STREAM: UInt8 = 1   # fuse into producer's op-chain (an op, not a sink)
comptime EDGE_E2_INGEST_STREAM: UInt8 = 2   # producer folds each morsel incrementally
comptime EDGE_E3_PUBLISH_WAIT: UInt8 = 3    # whole producer state before first output
comptime EDGE_E4_PARTITION_WISE: UInt8 = 4  # a complete partition, not the whole producer (latent)
comptime EDGE_E5_INDEPENDENT: UInt8 = 5     # no data dep (a scheduling relation)

# ---- order_key_kind (the COMBINE-MERGE order; NOT result
#      insertion-order). A per-segment enum: the N per-worker partial states reduce
#      in THIS order (not completion order), so a Class-FLOAT fold is byte-identical
#      across schedules.
comptime ORDER_NONE: UInt8 = 0
comptime ORDER_PARTITION_ID: UInt8 = 1
comptime ORDER_ROW_RANGE: UInt8 = 2

# ---- sink_orientation (the SECOND registry-row selector).
# Every sink is columnar: there is no row orientation. Value 1 is retired and
# must not be reused; the remaining two keep their numbers.
comptime SINK_ORIENT_COLUMNAR: UInt8 = 0
comptime SINK_ORIENT_DICT_ENCODED: UInt8 = 2

# ---- sink_key_dtype (the ONE comptime axis, paid by the kernel not the shape;
#      selects the registry ROW). A closed UInt8 tag set — key-block dtype.
comptime KEY_DTYPE_NONE: UInt8 = 0    # ungrouped / scalar (no key block)
comptime KEY_DTYPE_I64: UInt8 = 1
comptime KEY_DTYPE_I32: UInt8 = 2
comptime KEY_DTYPE_F64: UInt8 = 3
comptime KEY_DTYPE_F32: UInt8 = 4
comptime KEY_DTYPE_STRING: UInt8 = 5


struct SourceSpecPod(Movable):
    """POD source spec — the closed 4-kind `SOURCE_*` vocabulary as an
    INLINE descriptor field (source symmetry: the source set is bounded and
    is NOT the growth axis a new SINK kind widens, so it stays inline, not erased).

    Exactly one variant is meaningful, keyed by the enclosing descriptor's
    `source_kind`:
      * SOURCE_PARQUET: `parquet_path` + `parquet_projection` (pushed) +
        `parquet_filter` (pushed decode filter).
      * SOURCE_SINK_OUTPUT: `dep_seg_ids[0]` = the producer segment whose output
        this reads.
      * SOURCE_CONCAT: `dep_seg_ids` = the N producer segments, concat order.
      * SOURCE_BATCH: `batch_handle_id` = index into the driver's batch table.

    Every field is inert: `String`, `Optional[List[String]]`, `Optional[Expr]`,
    `List[Int]`, `Int`, `Bool`. Passes the inert-IR lint.

    ⛔ THE PARQUET ARM IS LOSSY, AND `parquet_spec_is_total` IS HOW A CONSUMER
    FINDS OUT. It carries THREE of `ParquetSourceData`'s ELEVEN fields. Read that
    field before reconstructing one; see its own docstring."""

    var parquet_path: String                     # SOURCE_PARQUET
    var parquet_projection: Optional[List[String]]  # SOURCE_PARQUET (None = all cols)
    var parquet_filter: Optional[Expr]           # SOURCE_PARQUET (None = no pushed filter)
    var parquet_spec_is_total: Bool
    """SOURCE_PARQUET ONLY. True iff the three fields above REPRODUCE the scan
    this spec was minted from -- i.e. every other field of the
    `ParquetSourceData` a consumer would build is at its DEFAULT, so building one
    from `(parquet_path, parquet_projection, parquet_filter)` alone loses
    nothing.

    ⛔ WHAT IT EXISTS TO STOP: a silent-wrong-results class.
    `ParquetSourceData` has ELEVEN fields; this pod carries THREE. The
    eight it drops are `hive_partition_cols`, `hive_predicate`, `fs_descriptor`,
    `preserve_numeric_dict`, `explicit_paths`, `row_window`,
    `preserve_string_dict` (and the pod re-spells the other three). The mint site
    takes the path from `ScanData.source_path`, which is `ParquetSource.paths[0]`
    -- a DERIVED CACHE kept for single-path readers. So a consumer that
    rebuilds a `ParquetSourceData` from an untotal spec reads FILE 0 OF N and
    returns a well-formed batch with the other N-1 files' rows missing.
    A resident collect leaf that builds a `ParquetSourceData` from
    `source_path` alone (empty `explicit_paths`) silently decodes ONLY file 0.
    This pod is the same construction reached from the PHYSICAL side, and it
    is the one that crosses an ABI.

    ★ DERIVED, NEVER DECLARED -- same rule, same reason, as
    `MorselOp.project_reorders_only`. The verdict is computed at the CUT, from
    the `ScanData` in hand by the segment cutter (not in this tree), not stamped
    by whoever happens to construct a pod. A caller cannot assert it.

    ⚠ DEFAULT FALSE, SO EVERY OTHER PRODUCER FAILS CLOSED. A `SourceSpecPod`
    built by a test, or by any future minter that does
    not derive the verdict says "not total" and is refused by a consumer that
    checks -- which is the safe direction. A default of True would make every
    unaudited producer look audited.

    ⚠ TOTAL IS NOT THE SAME AS SINGLE-FILE. It is the conjunction the DEFAULTS
    define; widening the pod to carry `explicit_paths` (as
    `komira_pplan_wire.pplan_wire_codec` already does for the wire form, 8 of 10
    fields encoded and the other 2 REFUSED BY NAME) would make more specs total
    without changing this field's meaning."""
    var dep_seg_ids: List[Int]                   # SOURCE_SINK_OUTPUT (len 1) / SOURCE_CONCAT (len N)
    var batch_handle_id: Int                     # SOURCE_BATCH (-1 unused)

    def __init__(out self):
        """Empty spec (SOURCE_SINK_OUTPUT/CONCAT default: fill dep_seg_ids)."""
        self.parquet_path = String("")
        self.parquet_projection = None
        self.parquet_filter = None
        self.parquet_spec_is_total = False
        self.dep_seg_ids = List[Int]()
        self.batch_handle_id = -1

    @staticmethod
    def parquet(
        var path: String,
        var projection: Optional[List[String]],
        var pushed_filter: Optional[Expr],
        spec_is_total: Bool = False,
    ) -> SourceSpecPod:
        """Mint the SOURCE_PARQUET arm.

        `spec_is_total` DEFAULTS TO FALSE on purpose: it is a derived verdict
        about the scan, and a producer that does not derive it must not claim
        it. See the field's docstring."""
        var s = SourceSpecPod()
        s.parquet_path = path^
        s.parquet_projection = projection^
        s.parquet_filter = pushed_filter^
        s.parquet_spec_is_total = spec_is_total
        return s^

    @staticmethod
    def from_sink_output(producer_seg_id: Int) -> SourceSpecPod:
        var s = SourceSpecPod()
        s.dep_seg_ids.append(producer_seg_id)
        return s^

    @staticmethod
    def concat(var producer_seg_ids: List[Int]) -> SourceSpecPod:
        var s = SourceSpecPod()
        s.dep_seg_ids = producer_seg_ids^
        return s^

    @staticmethod
    def batch(handle_id: Int) -> SourceSpecPod:
        var s = SourceSpecPod()
        s.batch_handle_id = handle_id
        return s^

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


struct SegmentDescPod(Movable):
    """The shape-free POD descriptor for ONE segment (`source -> op-chain -> sink`,
    cut at a breaker) + its place in the DAG. Every field is POD — an Int, a
    UInt8 tag, a `Slab`/`List` of POD, or the inline `SourceSpecPod`. NO pointers,
    NO fn-ptrs, NO operator-by-value. The sink is a TAG TRIPLE that selects a
    registry ROW at bind time; the concrete sink type is elaborated only in that
    row's registration leaf, never here. Passes the inert-IR lint.

    Held in a driver-owned `List[SegmentDescPod]` (NEVER a byte-slab)."""

    # ---- THE VERSION DOOR (field #0 ON PURPOSE — see the door above) ----
    # The IR revision the PRODUCER was compiled against. Defaulted to
    # `PHYSICAL_PLAN_IR_VERSION` in `__init__`, so a pod minted by a `.so` built
    # at IR vN carries N and a consumer built at vM refuses it BY NAME instead
    # of reading a shifted layout. First field because it is the one word both
    # sides must agree on before any other offset is meaningful.
    var ir_version: Int

    var seg_id: Int                     # dense id; index into the runtime's per-seg tables

    # ---- SOURCE (tagged POD spec) ----
    var source_kind: UInt8              # SOURCE_PARQUET | SOURCE_BATCH | SOURCE_SINK_OUTPUT | SOURCE_CONCAT
    var source_spec: SourceSpecPod

    # ---- OP CHAIN (the LANDED closed tagged union; runtime-N, no comptime over N) ----
    var ops: Slab[MorselOp]             # {OP_FILTER, OP_PROJECT, OP_LIMIT, OP_JOIN_PROBE}; N is RUNTIME

    # ---- SINK (ERASED — a TAG TRIPLE, never a struct-by-value) ----
    var sink_kind: UInt8                # SINK_AGG | SINK_HASH_BUILD | SINK_SORT | ... | SINK_COLLECT
    var sink_key_dtype: UInt8           # KEY_DTYPE_* — the ONE comptime axis (selects the registry ROW)
    var sink_orientation: UInt8         # SINK_ORIENT_* — second registry-row selector
    var sink_param_id: Int              # INDEX into a driver-owned ERASED param table
    var sink_state_id: Int              # the seg whose ErasedHandle this folds INTO (default = seg_id)

    # ---- DEP EDGES (the DAG, as POD) ----
    var deps: List[Int]                 # producer seg-ids this segment's source/probes consume
    var edge_tags: List[UInt8]          # E1..E5 per incoming edge, PARALLEL to `deps`

    # ---- SCHEDULING METADATA (POD, advisory — drives policy, never elaboration) ----
    var partition_count: Int            # output partitions (E4); 1 = single output (today's universal case)
    var order_key_kind: UInt8           # ORDER_NONE | ORDER_PARTITION_ID | ORDER_ROW_RANGE
    var mem_estimate_bytes: Int         # feeds the saturation throttle — INITIAL-shape hint only
    var card_estimate_rows: Int         # feeds the parallel-finalize / skew cost model

    # ---- CANCEL / ERROR (POD slots — an INDEX, never a token/record by value) ----
    var cancel_slot: Int                # index into the driver's cancel-token table
    var error_slot: Int                 # index into the driver's per-segment error record (first-error-wins)

    def __init__(
        out self,
        seg_id: Int,
        source_kind: UInt8,
        var source_spec: SourceSpecPod,
        var ops: Slab[MorselOp],
        sink_kind: UInt8,
        sink_key_dtype: UInt8,
        sink_orientation: UInt8,
        sink_param_id: Int,
        sink_state_id: Int,
        var deps: List[Int],
        var edge_tags: List[UInt8],
        partition_count: Int = 1,
        order_key_kind: UInt8 = ORDER_NONE,
        mem_estimate_bytes: Int = 0,
        card_estimate_rows: Int = 0,
        cancel_slot: Int = -1,
        error_slot: Int = -1,
        ir_version: Int = PHYSICAL_PLAN_IR_VERSION,
    ):
        self.ir_version = ir_version
        self.seg_id = seg_id
        self.source_kind = source_kind
        self.source_spec = source_spec^
        self.ops = ops^
        self.sink_kind = sink_kind
        self.sink_key_dtype = sink_key_dtype
        self.sink_orientation = sink_orientation
        self.sink_param_id = sink_param_id
        self.sink_state_id = sink_state_id
        self.deps = deps^
        self.edge_tags = edge_tags^
        self.partition_count = partition_count
        self.order_key_kind = order_key_kind
        self.mem_estimate_bytes = mem_estimate_bytes
        self.card_estimate_rows = card_estimate_rows
        self.cancel_slot = cancel_slot
        self.error_slot = error_slot

    @always_inline
    def num_ops(self) -> Int:
        return len(self.ops)

    @always_inline
    def num_deps(self) -> Int:
        return len(self.deps)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass
