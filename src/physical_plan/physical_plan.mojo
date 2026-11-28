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

from plan_expr.expr import Expr
from plan_expr.agg_expr import AggExpr
from plan_ir.logical_plan import ExprArray, AggExprArray, JOIN_ALGO_HASH, AsofTolerance
from plan_expr.partition_expr import PartitionExpr
from plan_expr.fs_descriptor_pod import FsDescriptorPod
from plan_expr.null_order_policy import derived_nulls_first
from arrow.schema import RecordBatch, Schema, Field
from containers.slab import Slab

from physical_plan.csv_source_spec import CsvSourceSpec
from physical_plan.iceberg_scan_spec import IcebergScanSpec
from physical_plan.parquet_source_data import ParquetRowWindow, ParquetSourceData
from physical_plan.udf_call_spec import UdfCallSpec
from physical_plan.sink_data import (
    AggSinkData,
    AsofJoinSinkData,
    HashBuildSinkData,
    PartitionBySinkData,
    PartitionTopNSinkData,
    SMJBuildSinkData,
    SortSinkData,
    TopNSinkData,
    is_explicit_nulls_first_request,
)


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
#   14: `SegmentDescPod.morsel_rows` — the rows per morsel the HOST chose when it
#       lowered the segment (`host_profile.morsel_sizing_policy`),
#       recorded so nothing downstream re-derives it. 0 = not yet lowered.
#   15: `SOURCE_CSV` and `SourceSpecPod.csv_spec` (`csv_source_spec`) — one
#       local CSV file, its dialect and the columns the plan bound it at.
#   16: `SourceSpecPod.parquet_paths`, `parquet_partition_cols` and
#       `parquet_partition_values` — the file list and the Hive partition
#       constants of a Parquet source of several files. Empty for a spec of
#       one plain file, which is read from `parquet_path` as before.
#   17: `OP_UDF_APPLY`, `OP_UDF_FRAME`, `SOURCE_UDF_STEP`, `MorselOp.udf` and
#       `SourceSpecPod.udf_step` (`udf_call_spec`): a user-function call.
#   18: `SourceSpecPod.parquet_fs` — a Parquet source's store (default local).
#   19: `SOURCE_ICEBERG` and `SourceSpecPod.iceberg_spec` (`iceberg_scan_spec`) —
#       the planned data files, delete files and bound columns of one Iceberg
#       table snapshot. `ParquetSourceData` moved to `parquet_source_data`.
#   20: `SOURCE_JSONL` and `SourceSpecPod.jsonl_path` / `jsonl_schema` -- a
#       segment that reads one newline-delimited JSON file at a stated schema.
#   21: `TopNSinkData.offset` — the rows of the sort order a top-N skips
#       before the `n` it keeps (LIMIT n OFFSET m over a sort). 0 is the plain
#       top-N.
#   22: `SOURCE_AVRO` and `SourceSpecPod.avro_path` / `avro_schema` -- a
#       segment that reads one local Avro object container file and delivers
#       a stated subset of its columns.
#   Retired `MorselOp` tag values (4-13) are not reused.

comptime PHYSICAL_PLAN_IR_VERSION: Int = 22


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
            " physical_plan/physical_plan.mojo without bumping",
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
comptime SOURCE_CSV: UInt8 = 4         # Read one local CSV file
comptime SOURCE_UDF_STEP: UInt8 = 5    # A STEP user function, run once
comptime SOURCE_ICEBERG: UInt8 = 6     # Read the planned files of one Iceberg snapshot
comptime SOURCE_JSONL: UInt8 = 7       # Read one newline-delimited JSON file
comptime SOURCE_AVRO: UInt8 = 8        # Read one local Avro object container file

# MorselOp tags
comptime OP_FILTER: UInt8 = 0          # Predicate filter (SV-based)
comptime OP_PROJECT: UInt8 = 1         # Column projection / expression eval
comptime OP_LIMIT: UInt8 = 2           # Row count limit
comptime OP_JOIN_PROBE: UInt8 = 3      # Hash join probe (streaming)
# MorselOp tag values 4-13 are retired and must not be reused.
comptime OP_UDF_APPLY: UInt8 = 14      # A user-function call, one column appended
comptime OP_UDF_FRAME: UInt8 = 15      # A frame user function per morsel
# The next free tag id is 16.

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
# The descriptor contract
# =============================================================================
#
# `SegmentDescPod` + `SourceSpecPod` below are the live descriptor contract.
# The sink there is a TAG TRIPLE precisely so it is never a sink struct
# carried by value. `ParquetSourceData`, `MorselOp`, and every `*SinkData`
# struct (`AggSinkData`, `SortSinkData`, `TopNSinkData`, `PartitionBySinkData`,
# `PartitionTopNSinkData`, `AsofJoinSinkData`, `HashBuildSinkData`,
# `SMJBuildSinkData`, defined in `sink_data` and imported here) each have
# independent consumers in the engine's operators, which are not in this tree.
# =============================================================================

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
        OP_UDF_APPLY, OP_UDF_FRAME: A user-function call, `udf`.

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
    var udf: Optional[UdfCallSpec]  # OP_UDF_APPLY / OP_UDF_FRAME (`udf_call_spec`)

    @staticmethod
    def udf_call(tag: UInt8, var spec: UdfCallSpec) -> MorselOp:
        """Create an OP_UDF_APPLY or OP_UDF_FRAME operator."""
        var op = MorselOp(tag=tag)
        op.udf = spec^
        return op^

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
        self.udf = None

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
# A DATE32 key (the day number), a BOOL key, and a DECIMAL128 key (its 128-bit
# unscaled value at the declared scale). Added after 5 without renumbering; an
# engine that predates a tag refuses its triple by name when it builds the sink.
comptime KEY_DTYPE_DATE32: UInt8 = 6
comptime KEY_DTYPE_BOOL: UInt8 = 7
comptime KEY_DTYPE_DECIMAL128: UInt8 = 8
# A group key of two or more columns whose types are not all one family, or
# whose strings are not all dictionary encoded: each column keeps its own type
# (a STRING, or any type a fixed-width row above keys), so the key block is a
# row of cells laid out column by column. Added after 8 without renumbering.
comptime KEY_DTYPE_COMPOSITE: UInt8 = 9


struct SourceSpecPod(Movable):
    """POD source spec — the closed 9-kind `SOURCE_*` vocabulary as an
    INLINE descriptor field (source symmetry: the source set is bounded and
    is NOT the growth axis a new SINK kind widens, so it stays inline, not erased).

    Exactly one variant is meaningful, keyed by the enclosing descriptor's
    `source_kind`:
      * SOURCE_PARQUET: `parquet_path` + `parquet_projection` (pushed) +
        `parquet_filter` (pushed decode filter); a source of several files or
        with Hive partition columns also carries `parquet_paths`,
        `parquet_partition_cols` and `parquet_partition_values`; `parquet_fs`
        names the store the files are on.
      * SOURCE_SINK_OUTPUT: `dep_seg_ids[0]` = the producer segment whose output
        this reads.
      * SOURCE_CONCAT: `dep_seg_ids` = the N producer segments, concat order.
      * SOURCE_BATCH: `batch_handle_id` = index into the driver's batch table.
      * SOURCE_CSV: `csv_spec`, the file, its dialect and its bound columns
        (`csv_source_spec`).
      * SOURCE_UDF_STEP: `udf_step`, the call (`udf_call_spec`).
      * SOURCE_ICEBERG: `iceberg_spec`, the planned data and delete files and
        the bound columns (`iceberg_scan_spec`).
      * SOURCE_JSONL: `jsonl_path` + `jsonl_schema` (the keys read, in the
        order the source delivers them, each at the type it is read as).
      * SOURCE_AVRO: `avro_path` + `avro_schema` (the columns delivered, in
        order, each at the type the file's header gives it).

    Every field is inert: `String`, `Optional[List[String]]`, `Optional[Expr]`,
    `List[Int]`, `List[Field]`, `List[List[String]]`, `Int`, `Bool`, `Schema`,
    `FsDescriptorPod` (a `UInt8`, a `String`, an `Int`), and `CsvSourceSpec`,
    `UdfCallSpec` and `IcebergScanSpec` of the same kinds. Passes the inert-IR lint.

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
    eight it drops are `hive_partition_cols`, `hive_predicate`, `fs_descriptor`
    (since IR 18 `parquet_fs`), `preserve_numeric_dict`, `explicit_paths`, `row_window`,
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
    define. Since IR version 16 the pod carries the file list
    (`parquet_paths`) and the Hive partition constants, so a source of several
    files is total too, and since 18 so is an S3, GCS or Azure scan
    (`parquet_fs`); an unknown store, an unbounded scan or a lazy Hive shape
    (a directory scan, a partition predicate) is refused at the cut."""
    var parquet_paths: List[String]
    """SOURCE_PARQUET ONLY. Every file of the source, in read order. Empty for
    a spec built by `parquet()`, which names one file in `parquet_path`; a spec
    built by `parquet_files()` lists them, and `parquet_path` is the first."""
    var parquet_partition_cols: List[Field]
    """SOURCE_PARQUET ONLY. The Hive partition columns, after the files' own
    columns. Empty when the files carry none."""
    var parquet_partition_values: List[List[String]]
    """SOURCE_PARQUET ONLY. `[file][column]`: the decoded value text of each
    partition column for each file of `parquet_paths`. Empty when
    `parquet_partition_cols` is."""
    var parquet_fs: FsDescriptorPod  # SOURCE_PARQUET: the store; a bucket's paths are object keys
    var dep_seg_ids: List[Int]                   # SOURCE_SINK_OUTPUT (len 1) / SOURCE_CONCAT (len N)
    var batch_handle_id: Int                     # SOURCE_BATCH (-1 unused)
    var csv_spec: CsvSourceSpec                  # SOURCE_CSV (empty = the CSV defaults)
    var udf_step: Optional[UdfCallSpec]          # SOURCE_UDF_STEP
    var iceberg_spec: IcebergScanSpec            # SOURCE_ICEBERG (empty = no files, no columns)
    var jsonl_path: String                       # SOURCE_JSONL
    var jsonl_schema: Schema
    """SOURCE_JSONL ONLY. The columns the source delivers: one per JSON key it
    reads, in order, at the type the key's values are read as. A key the schema
    does not name is skipped; a key a line lacks reads NULL. The schema is the
    one the plan was bound at, so the file is never inferred again."""
    var avro_path: String                        # SOURCE_AVRO
    var avro_schema: Schema
    """SOURCE_AVRO ONLY. The columns the source delivers, in order: a subset
    of the file's columns, each at the type the plan bound it at (the one the
    file's header gives it). A column of the file the schema does not name is
    decoded and dropped."""

    def __init__(out self):
        """Empty spec (SOURCE_SINK_OUTPUT/CONCAT default: fill dep_seg_ids)."""
        self.parquet_path = String("")
        self.parquet_projection = None
        self.parquet_filter = None
        self.parquet_spec_is_total = False
        self.parquet_paths = List[String]()
        self.parquet_partition_cols = List[Field]()
        self.parquet_partition_values = List[List[String]]()
        self.parquet_fs = FsDescriptorPod.local()
        self.dep_seg_ids = List[Int]()
        self.batch_handle_id = -1
        self.csv_spec = CsvSourceSpec()
        self.udf_step = None
        self.iceberg_spec = IcebergScanSpec()
        self.jsonl_path = String("")
        self.jsonl_schema = Schema()
        self.avro_path = String("")
        self.avro_schema = Schema()

    @staticmethod
    def parquet(
        var path: String,
        var projection: Optional[List[String]],
        var pushed_filter: Optional[Expr],
        spec_is_total: Bool = False,
        var fs: FsDescriptorPod = FsDescriptorPod.local(),
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
        s.parquet_fs = fs^
        return s^

    @staticmethod
    def parquet_files(
        var paths: List[String],
        var partition_cols: List[Field],
        var partition_values: List[List[String]],
        var projection: Optional[List[String]],
        var pushed_filter: Optional[Expr],
        var fs: FsDescriptorPod = FsDescriptorPod.local(),
    ) -> SourceSpecPod:
        """Mint the SOURCE_PARQUET arm for a source of several files, or of
        files with Hive partition columns: total, `parquet_path` the first
        file. The shape (one value row per file, one entry per column) is the
        source's (`ParquetSource.partitioned`) and is checked again by the
        consumer that opens the files (`ExplicitFileDiscovery.from_files`)."""
        var s = SourceSpecPod()
        if len(paths) > 0:
            s.parquet_path = String(paths[0])
        s.parquet_paths = paths^
        s.parquet_partition_cols = partition_cols^
        s.parquet_partition_values = partition_values^
        s.parquet_projection = projection^
        s.parquet_filter = pushed_filter^
        s.parquet_spec_is_total = True
        s.parquet_fs = fs^
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

    @staticmethod
    def csv(var spec: CsvSourceSpec) -> SourceSpecPod:
        """Mint the SOURCE_CSV arm."""
        var s = SourceSpecPod()
        s.csv_spec = spec^
        return s^

    @staticmethod
    def iceberg(var spec: IcebergScanSpec) -> SourceSpecPod:
        """Mint the SOURCE_ICEBERG arm."""
        var s = SourceSpecPod()
        s.iceberg_spec = spec^
        return s^

    @staticmethod
    def step(var spec: UdfCallSpec) -> SourceSpecPod:
        """Mint the SOURCE_UDF_STEP arm."""
        var s = SourceSpecPod()
        s.udf_step = spec^
        return s^

    @staticmethod
    def jsonl(var path: String, var schema: Schema) -> SourceSpecPod:
        """Mint the SOURCE_JSONL arm: the file at `path`, read at `schema`."""
        var s = SourceSpecPod()
        s.jsonl_path = path^
        s.jsonl_schema = schema^
        return s^

    @staticmethod
    def avro(var path: String, var schema: Schema) -> SourceSpecPod:
        """Mint the SOURCE_AVRO arm: the Avro file at `path`, delivering the
        columns of `schema`."""
        var s = SourceSpecPod()
        s.avro_path = path^
        s.avro_schema = schema^
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
    var source_kind: UInt8              # SOURCE_PARQUET | SOURCE_BATCH | SOURCE_SINK_OUTPUT | SOURCE_CONCAT | SOURCE_CSV | SOURCE_UDF_STEP | SOURCE_ICEBERG | SOURCE_JSONL | SOURCE_AVRO
    var source_spec: SourceSpecPod

    # ---- OP CHAIN (the LANDED closed tagged union; runtime-N, no comptime over N) ----
    var ops: Slab[MorselOp]             # {OP_FILTER, OP_PROJECT, OP_LIMIT, OP_JOIN_PROBE, OP_UDF_*}; N is RUNTIME

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

    # ---- HOST-RECORDED LOWERING DECISIONS (written by the host, never by the producer) ----
    var morsel_rows: Int                # rows per morsel, a pure function of (host profile, segment); 0 = not lowered

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
        morsel_rows: Int = 0,
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
        self.morsel_rows = morsel_rows
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
