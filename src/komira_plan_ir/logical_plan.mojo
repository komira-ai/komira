# =============================================================================
# LogicalPlan — the relational plan tree for the Komira compiler pipeline
# =============================================================================
#
# A tree of relational operations. Each node represents a transformation on
# a table (set of rows and columns). The tree is built bottom-up: leaf nodes
# are Scan operations, and each subsequent operation wraps the previous as
# a child.
#
# Mojo does not have recursive structs. We use OwnedPointer[LogicalPlan]
# for heap-allocated child references (like Rust's Box<LogicalPlan>).
# The tagged-struct + Optional pattern matches the Expr implementation.
#
# Memory layout:
#     tag: UInt8                                              -- node type discriminant
#     output_schema: Schema                                   -- output schema of this node
#     _scan: Optional[OwnedPointer[ScanData]]                 -- populated when tag == PLAN_SCAN
#     _filter: Optional[OwnedPointer[FilterData]]             -- populated when tag == PLAN_FILTER
#     _project: Optional[OwnedPointer[ProjectData]]           -- populated when tag == PLAN_PROJECT
#     _aggregate: Optional[OwnedPointer[AggregateData]]       -- populated when tag == PLAN_AGGREGATE
#     _join: Optional[OwnedPointer[JoinData]]                 -- populated when tag == PLAN_JOIN
#     _sort: Optional[OwnedPointer[SortData]]                 -- populated when tag == PLAN_SORT
#     _limit: Optional[OwnedPointer[LimitData]]               -- populated when tag == PLAN_LIMIT
#     _distinct: Optional[OwnedPointer[DistinctData]]         -- populated when tag == PLAN_DISTINCT
#     _topn: Optional[OwnedPointer[TopNData]]                 -- populated when tag == PLAN_TOPN
#     _partition_by: Optional[OwnedPointer[PartitionByData]]  -- populated when tag == PLAN_PARTITION_BY
#     _partition_topn: Optional[OwnedPointer[PartitionTopNData]] -- populated when tag == PLAN_PARTITION_TOPN
#     _asof_join: Optional[OwnedPointer[AsofJoinData]]        -- populated when tag == PLAN_ASOF_JOIN
#
# Only one Optional is populated at a time. The others are None.
#
# WHY EACH VARIANT IS AN `OwnedPointer`:
# Each variant Data is wrapped in `OwnedPointer[T]`, so a `None` Optional
# is a 1-byte discriminant + 8-byte handle slot (~16 B with alignment)
# instead of `sizeof(Data)` bytes of cold zeros — a ~10-node deep-copy
# carries ~176 B of Optional bookkeeping rather than ~960 B.
#
# More importantly: it allows partial-move-out via `Optional.take()`
# (returns the inner OwnedPointer; original Optional becomes None; struct
# is then safely droppable without UnsafePointer-to-field gymnastics),
# which tree-shape optimizer rules and compile-node moves rely on — the
# alternative, `UnsafePointer(to=struct.field).take_pointee()`, is banned.
#
# Access shape:
#   Field type:    Optional[OwnedPointer[FooData]]
#   Read pattern:  plan._foo.value()[].<field>
#   Construct:     plan._foo = OwnedPointer(FooData(...))
#   Truthiness:    `if plan._foo:` (Optional is bool-checked).
#   Accessor refs: `ref [self._foo.value()] FooData` bodies
#                  `return self._foo.value()[]`.
# =============================================================================

from std.memory import OwnedPointer, ArcPointer

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_PARQUET,
    SOURCE_VARIANT_IN_MEMORY,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.in_memory_source import InMemorySource
from komira_scan_source.json_source import JsonSource
from komira_scan_source.csv_source import CsvSource
from komira_buffer.file_identity import FileIdentity
from komira_plan_expr.expr import Expr, EXPR_COL_REF, EXPR_ALIAS, EXPR_LITERAL, EXPR_BINARY_OP, EXPR_CAST, EXPR_WHEN, EXPR_STRING_OP, EXPR_STRING_FN, EXPR_UDF_CALL, string_fn_returns_int, EXPR_REGEXP, EXPR_SUBSTRING, EXPR_STRUCT_FIELD, EXPR_STRUCT_FIELD_IDX, EXPR_MAP_GET, EXPR_MATH_FN, EXPR_MATH_FN2, EXPR_IN_LIST, EXPR_BETWEEN, REGEXP_LIKE, REGEXP_MATCH, REGEXP_REPLACE, REGEXP_SPLIT_TO_ARRAY, REGEXP_EXTRACT_ALL, REGEXP_COUNT, REGEXP_INSTR, REGEXP_SUBSTR, REGEXP_FULL_MATCH, BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX, AGG_MEAN, AGG_COUNT_DISTINCT, AGG_FIRST, AGG_LAST, AGG_STDDEV_SAMP, AGG_VAR_SAMP, AGG_CORR, AGG_MEDIAN, AGG_LARGEST_K, AGG_COVAR_POP, AGG_COVAR_SAMP, AGG_REGR_AVGX, AGG_REGR_AVGY, AGG_REGR_COUNT, AGG_REGR_SXX, AGG_REGR_SXY, AGG_REGR_SYY, AGG_REGR_SLOPE, AGG_REGR_INTERCEPT, AGG_REGR_R2, AGG_VAR_POP, AGG_STDDEV_POP, AGG_SEM, AGG_COUNT_IF, AGG_BOOL_AND, AGG_BOOL_OR, AGG_PRODUCT, agg_is_bool_valued, AGG_ANY_VALUE, AGG_KAHAN_SUM, AGG_KAHAN_AVG, AGG_SKEWNESS, AGG_KURTOSIS, AGG_KURTOSIS_POP
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr, partition_expr_output_field
from komira_plan_stats.table_stats import TableStats
# Filter / Project / Aggregate carry an optional typed-UDF `udf` field,
# `Optional[OwnedPointer[UdfData]]` (None on the ordinary Expr path; populated
# by `df.filter_udf[F: FilterFn]` / `.map_udf[M: MapFn]` / `.agg_udf[A: AggFn]`).
# Factory methods `filter_with_udf` / `project_with_udf` / `aggregate_with_udf`
# wrap the IR + UdfData together.
from komira_plan_expr.udf_data import UdfData, arrow_type_of_dtag

# `_infer_expr_field` below is an ADAPTER
# over the ONE output-field inference; see `expr_walk.mojo`'s header.
from komira_plan_expr.expr_walk import walk_expr_field, PlanColRefFields


# =============================================================================
# Tag constants (UInt8-backed for compact storage)
# =============================================================================

comptime PLAN_SCAN: UInt8 = 0
comptime PLAN_FILTER: UInt8 = 1
comptime PLAN_PROJECT: UInt8 = 2
comptime PLAN_AGGREGATE: UInt8 = 3
comptime PLAN_JOIN: UInt8 = 4
comptime PLAN_SORT: UInt8 = 5
comptime PLAN_LIMIT: UInt8 = 6
comptime PLAN_DISTINCT: UInt8 = 7
comptime PLAN_TOPN: UInt8 = 8
comptime PLAN_PARTITION_BY: UInt8 = 9
comptime PLAN_PARTITION_TOPN: UInt8 = 10
comptime PLAN_ASOF_JOIN: UInt8 = 11
# A variadic UNION ALL node — concatenates
# the row-streams of N children that all share the same output schema.
# Its producer is `plan_compiler._lower_multi_file_parquet_scan`
# (a multi-path / Hive-partitioned `ParquetSource` lowers to
# `Union(Scan(f1), Scan(f2), ...)` — Hive: `Union(Project(Scan(fi),
# [*, lit AS pcol]), ...)`). SQL `UNION` / `UNION ALL` / `EXCEPT` /
# `INTERSECT` as user-facing set operations are not built on it; this
# node is just enough to make multi-file scans execute.
comptime PLAN_UNION: UInt8 = 12
# A lazy reference to a registered view.
# `ctx.view(handle)` returns a DataFrame whose plan is a single
# `PLAN_VIEW_REF` leaf carrying the view's NAME + output Schema. The
# `view_resolution_pass` compiler sub-pass (runs in pass-1 of `optimize()`,
# BEFORE `flatten_dependent_joins` and BEFORE the structural_hash is taken)
# replaces each `PLAN_VIEW_REF` with the registered view's expanded plan
# (recursively — view-of-view; depth limit 16; cycle detection via a
# name-stack). After resolution, two consumers of the same view produce
# identical structural_hashes (→ plan-compile cache hit). A
# `PLAN_VIEW_REF` that survives to plan-compile time is a bug (the engine
# has no handler for it) — the resolution pass is an assertable invariant
# of the optimizer pipeline.
comptime PLAN_VIEW_REF: UInt8 = 13
# A leaf reference to the
# CANONICAL occurrence of a duplicated PURE subtree, keyed on that
# subtree's `structural_hash`. Produced ONLY by `plan_cse.plan_cse_eliminate`
# (the plan-level CSE rewrite) and ONLY when the rewrite gate
# (`plan_cse._ENABLE_CSE_REWRITE`) is on. The IR stays a TREE (not a DAG):
# the canonical occurrence keeps the full subtree; the 2nd..Nth occurrences
# become `PLAN_CSE_REF` leaves carrying `canonical_hash`. `plan_compiler`'s
# `_compile_node` arm for this tag resolves it to a fragment sourced from
# the segment that computed the canonical subtree's result. NB: the engine
# currently enforces a HARD single-consumer invariant on segment outputs —
# until that grows a per-seg consumer counter, the CSE rewrite gate stays
# OFF and a `PLAN_CSE_REF` never reaches plan-compile in production (the
# `_compile_node` arm raises a clear deferral error if it ever does).
comptime PLAN_CSE_REF: UInt8 = 14
# cast_to_varchar: a single-child node that wraps its input with
# `CastToVarcharOp` (`komira_engine_operators/cast_to_varchar.mojo`). The
# node's output_schema is the per-column STRING-typed mirror of the child
# (synthesized at factory time). Producer: `cast_to_varchar_insert.mojo`
# walks the plan top and inserts ONE PLAN_CAST_TO_VARCHAR above a root
# whose feeding sink reports `is_text_output_sink() == True` (CSV/JSONL
# / WholeFileCompressed[CSV|JSONL,*]). Idempotent: the insertion rule
# observes an existing PLAN_CAST_TO_VARCHAR at the root and no-ops.
# Sinks that consume Arrow-typed batches directly (ArrowCStreamSink,
# Parquet, Arrow IPC, InMemorySink) report False and do NOT trigger the
# rewrite. The plan-compile-cache key folds `is_text_output_sink()` into
# the full SinkVariant config hash so `write_csv("/a")` and
# `write_csv("/b")` share cache keys but `write_csv` and `write_parquet`
# do not (paths excluded from the hash).
comptime PLAN_CAST_TO_VARCHAR: UInt8 = 15


# =============================================================================
# Tag names — THE ONE PLACE A `PLAN_*` TAG GETS A HUMAN NAME
# =============================================================================
#
# WHY THIS IS HERE AND NOT NEXT TO A RENDERER. A hand-copied tag-label table
# next to a renderer goes stale: one that models only some tags prints
# `Unknown(tag=N)` for the rest, and one whose "unknown" sentinel shares an id
# with a real tag mislabels a real, well-formed node.
#
# A label table belongs at the DEFINITION site of the thing it labels. Adding a
# `PLAN_*` constant above means adding one arm here, and every reader gets
# it. `PLAN_TAG_COUNT` is what histogram-shaped consumers size themselves from,
# so it cannot fall behind either.
#
# This file is the ONE declaration site for the PLAN_* space, so "the whole
# tag space" and "the part declared in this file" are the same set. Tag ids 16
# and 17 are RETIRED (wire numbers 17 and 18 are reserved forever), and the
# next plan tag takes id 18 (wire number 19).

comptime PLAN_TAG_COUNT: Int = 16
"""One past the highest `PLAN_*` tag id — `PLAN_CAST_TO_VARCHAR = 15`.

⛔ THE NEXT TAG ADDED TAKES 18, NOT 16. Ids 16 and 17 are retired; reusing
either would silently mis-decode any old bytes that still carry a node with
that id — the same reason `plan.proto` RESERVES a retired field number rather
than renumbering around it. Reserving the NUMBER is permanent."""


def _write_plan_tag_name[W: Writer](mut writer: W, tag: UInt8):
    """WRITE what `plan_tag_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a
    shared library can bind such a pair CROSSED and crash the host
    interpreter."""
    if tag == PLAN_SCAN:
        writer.write(String("Scan"))
        return
    if tag == PLAN_FILTER:
        writer.write(String("Filter"))
        return
    if tag == PLAN_PROJECT:
        writer.write(String("Project"))
        return
    if tag == PLAN_AGGREGATE:
        writer.write(String("Aggregate"))
        return
    if tag == PLAN_JOIN:
        writer.write(String("Join"))
        return
    if tag == PLAN_SORT:
        writer.write(String("Sort"))
        return
    if tag == PLAN_LIMIT:
        writer.write(String("Limit"))
        return
    if tag == PLAN_DISTINCT:
        writer.write(String("Distinct"))
        return
    if tag == PLAN_TOPN:
        writer.write(String("TopN"))
        return
    if tag == PLAN_PARTITION_BY:
        writer.write(String("PartitionBy"))
        return
    if tag == PLAN_PARTITION_TOPN:
        writer.write(String("PartitionTopN"))
        return
    if tag == PLAN_ASOF_JOIN:
        writer.write(String("AsofJoin"))
        return
    if tag == PLAN_UNION:
        writer.write(String("Union"))
        return
    if tag == PLAN_VIEW_REF:
        writer.write(String("ViewRef"))
        return
    if tag == PLAN_CSE_REF:
        writer.write(String("CseRef"))
        return
    if tag == PLAN_CAST_TO_VARCHAR:
        writer.write(String("CastToVarchar"))
        return
    # ⛔ 16 / 17 ARE RETIRED IDS — DO NOT REUSE THEM FOR A NEW TAG.
    # A plan carrying 16 or 17 renders as `tag#16` / `tag#17` — which is
    # correct: no such node can be produced, and a plan that carries one is
    # old bytes, not a live tag. The NEXT tag added takes 18, never 16.
    writer.write(String("tag#") + String(Int(tag)))
    return


def plan_tag_name(tag: UInt8) -> String:
    """Human name for a `PLAN_*` tag id.

    An id with no arm renders as `tag#<n>` rather than being dropped or
    silently aliased onto a neighbour, so a tag added without being named here
    is VISIBLE wherever it is printed.
    """
    var out = String()
    _write_plan_tag_name(out, tag)
    return out^


# =============================================================================
# Source type constants
# =============================================================================

comptime SOURCE_PARQUET: UInt8 = 0
comptime SOURCE_CSV: UInt8 = 1
comptime SOURCE_NDJSON: UInt8 = 2
comptime SOURCE_IN_MEMORY: UInt8 = 3
# JSON columnar materializer source.
# Distinct from SOURCE_NDJSON — same file format on disk but a different
# decode path: SOURCE_JSON drives the direct-to-Arrow walker
# (komira_json/columnar_materializer.mojo) producing columnar batches in one
# pass.
comptime SOURCE_JSON: UInt8 = 4
# Apache ORC v1 source.
# Like SOURCE_JSON, this is COLUMNAR-decoded (the komira_orc reader emits
# Arrow batches directly via column accumulators).
comptime SOURCE_ORC: UInt8 = 5
# Apache Avro OCF source — a ROW-layout format: each OCF record is decoded
# as a whole.
#
# ⚠ DECLARED DATA. This constant and the ROW orientation are declared on the
# kind's binding (`ScanBinding.legacy_source_type` / `orientation`), not
# threaded by callers: an unstated `source_kind` over an AVRO scan derives ROW
# from the declaration.
comptime SOURCE_AVRO: UInt8 = 6
# Arrow IPC file source. COLUMNAR.
#
# ⚠ WITHOUT THIS CONSTANT an Arrow scan would be labelled `SOURCE_PARQUET` with
# an EMPTY path by `ScanData.__init__`'s derivation — which is what optimizer
# sites (`optimizer_scan_dedup`, `join_node_exec`, `segment_cutter`, ...) key
# on. Falsifier: `test_scan_binding_arrow_arm.mojo
# :test_arrow_scan_is_not_labelled_parquet`.
comptime SOURCE_ARROW: UInt8 = 7
# "A kind identified by `ScanBinding.kind_id`, not by this enum."
#
# This enum is a closed set, so the open arm's honest answer is "not one of
# these". A consumer that needs to know WHICH kind reads
# `scan.source.binding_ref().kind_id` — a `UInt32` hashed from a reverse-DNS
# name, which needs no central allocation table and therefore no edit here.
# Every `source_type == SOURCE_PARQUET` site correctly declines this value.
comptime SOURCE_BINDING: UInt8 = 8


# =============================================================================
# SOURCE LAYOUT — THE PHYSICAL SHAPE OF THE FILE. ⛔ NOT AN EXECUTOR SELECTOR.
# =============================================================================
#
# ⭐ WHY "ROW" IS NOT "CSV", AND WHAT THE VALUE SELECTS: the format picks the
# layout, and the layout picks a READER. It does not pick an executor — there
# is one, columnar, engine; a routing predicate that would select a row-mode
# executor (`route_plan_shape_row_streaming` in `komira_engine_dispatch`) is
# `return False` UNCONDITIONALLY.
#
# ✅ WHAT IT IS: A TRUE PHYSICAL FACT ABOUT THE BYTES ON DISK, which is what
# reaches the right READER.
#
#   SOURCE_KIND_COLUMNAR — Parquet, ORC, Arrow IPC, in-memory RecordBatches.
#     The file stores a COLUMN at a time, so the reader can seek to one column
#     and decode it without touching the others.
#   SOURCE_KIND_ROW      — CSV, NDJSON, Avro OCF. The file stores a RECORD at a
#     time, so a row's columns are interleaved and the decoder must walk the
#     whole record to reach any one field of it.
#
# Nothing about execution can falsify that: it is a property of the FORMAT. Both
# layouts are executed by the ONE columnar engine, so ROW means "this reader
# transposes on the way in", NOT "this plan runs somewhere else".
#
# ⭐ AND IT IS DERIVED, NOT STATED — `derive_source_layout` below is the single
# authority, and `ScanData.__init__` calls it. A binding-backed source answers
# with its KIND'S DECLARED `orientation` (`komira.csv` / `komira.json` /
# `komira.avro` declare ROW; `komira.parquet` / `komira.orc` /
# `komira.arrow` declare COLUMNAR); the two non-binding-backed arms
# (PARQUET, IN_MEMORY) are columnar.
#
# ⛔⛔ THE `SOURCE_KIND_*` NAMES ARE PUBLISHED WIRE NAMES, SO RENAMING THEM IS
# NOT A LOCAL EDIT. The plan-wire vocabulary generator scrapes THIS FILE for
# `SOURCE_KIND_`-prefixed `comptime` lines and emits each identifier VERBATIM
# as a value name of `enum SourceOrientation` in `plan_vocabulary.proto`,
# recorded in an APPEND-ONLY baseline. The compatibility check refuses a
# published wire number whose NAME changes, and there is no escape hatch for a
# rename. So spelling these `SOURCE_LAYOUT_*` is a WIRE-VOCABULARY MIGRATION
# (retire the whole `SourceOrientation` space, publish a new one, regenerate
# the `.proto`, the codec and every plan-wire fixture), not a rename.

comptime SOURCE_KIND_COLUMNAR: UInt8 = 0
comptime SOURCE_KIND_ROW: UInt8 = 1

# -----------------------------------------------------------------------------
# THE CALLER DID NOT STATE A KIND — derive it.
# -----------------------------------------------------------------------------
# With a DEFAULT of `SOURCE_KIND_COLUMNAR`, "the caller said COLUMNAR" and "the
# caller said nothing" would be the SAME VALUE and `ScanData.__init__` could
# not tell them apart — the binding's DECLARED `orientation` would be a mere
# default instead of an authority.
#
# With a distinct "unset" value the three cases separate: unset -> derive;
# stated and AGREEING -> fine; stated and CONTRADICTING a binding-backed kind
# -> a named error, because `orientation` is DECLARED DATA and a caller does
# not get to overrule the kind about its own physical shape.
#
# 255 cannot collide: the real values are 0 and 1. Same shape, same reason, as
# `SCAN_LEGACY_SOURCE_TYPE_NONE`.
comptime SOURCE_KIND_UNSET: UInt8 = 255


def derive_source_layout(imm source: SourceVariant) -> UInt8:
    """⭐ THE SINGLE AUTHORITY on a scan's PHYSICAL LAYOUT — derived from the
    SOURCE, never stated by a caller. See the banner above the constants.

    `SOURCE_KIND_COLUMNAR` iff the file stores a column at a time; `_ROW` iff it
    stores a record at a time. The answer is a fact about the FORMAT, so the
    format is the only thing asked:

      * BINDING-BACKED  -> the kind's DECLARED `orientation`. `komira.csv`,
        `komira.json` and `komira.avro` declare ROW; `komira.parquet`,
        `komira.orc` and the three `komira.arrow*` kinds declare COLUMNAR.
        `ScanKindRegistry.validate` RAISES when a binding's orientation differs
        from its descriptor's, so the declaration is checked data, not a hint.
      * NOT BINDING-BACKED -> COLUMNAR. The two non-binding-backed arms are
        PARQUET and IN_MEMORY, and both are columnar. There is no row-shaped
        source that reaches a plan without a binding.

    ⚠ A NAMED FUNCTION AND NOT AN INLINE LADDER: the value has to be
    CHECKABLE, so a test can ask it per SOURCE rather than per `source_type`
    tag.

    ⚠ THIS IS A DERIVATION, NOT A POLICY, SO IT MUST NOT RAISE. `ScanData
    .__init__` calls it and `ScanData.copy()` reaches that ctor; a deep clone
    cannot fail. The one thing a caller can get WRONG — stating a layout that
    contradicts a declaration — is refused by `_require_orientation_agreement`
    at `scan_from_source`, which is a `raises` door.

    Args:
        source: The scan's source variant (borrowed; not consumed).

    Returns:
        `SOURCE_KIND_COLUMNAR` or `SOURCE_KIND_ROW`. Never `SOURCE_KIND_UNSET` —
        a derivation that cannot answer is not a derivation.
    """
    if source.is_binding_backed():
        return source.binding_ref().orientation
    return SOURCE_KIND_COLUMNAR


def _require_orientation_agreement(
    source: SourceVariant, source_kind: UInt8
) raises:
    """Refuse a `source_kind` that contradicts a binding-backed kind's DECLARED
    `orientation`.

    ⚠ THIS REPORTS THE RULE; `ScanData.__init__` ENFORCES IT. That ctor ignores
    `source_kind` entirely for a binding-backed source, so a contradiction can
    never take effect — but the ctor must stay NON-RAISING (`ScanData.copy()`
    reaches it and a deep clone cannot fail), so it cannot tell the caller.
    This function is called from `scan_from_source`.

    Raising from the ctor instead would force `raises` onto `ScanData.copy()`:
    a `def` does NOT carry an implicit `raises` (`'raise' requires a
    surrounding 'try' block or the enclosing function to declare 'raises'`),
    so a raising ctor forces `raises` onto `ScanData.copy()`, therefore onto
    `LogicalPlan.copy()` — a deep clone called from everywhere that cannot fail
    — and the obligation propagates transitively through the test tree
    (dozens of helper signatures across dozens of files). Same correctness,
    one `raises` instead of hundreds.

    The legacy `LogicalPlan.scan` factory CAN build a binding-backed variant
    (`LogicalPlan.scan(path, SOURCE_NDJSON, ...)` builds a
    `SourceVariant(JsonSource)`), and it PASSES NO `source_kind`, so it cannot
    contradict a declaration by construction; a test runs this refusal over
    what that factory builds so the property is measured rather than asserted.

    ⚠ RESIDUAL, STATED. `LogicalPlan.scan` does not CALL this check. Making it
    do so needs `raises` on a factory with very many caller files — the same
    cascade this note is about. The mechanism is therefore the test, not the
    type system: "a rule checked at one door and enforced at the ctor, with a
    test standing at the other door".
    """
    if not source.is_binding_backed():
        # No declaration exists; the caller's value is honoured verbatim.
        return
    if source_kind == SOURCE_KIND_UNSET:
        return
    var declared = source.binding_ref().orientation
    if source_kind == declared:
        # Agreeing is not contradicting. A rebuild site that faithfully
        # re-threads the value it read off the old ScanData must not fail.
        return
    raise Error(
        String("scan_from_source: caller passed source_kind=")
        + String(source_kind)
        + String(" but scan kind '")
        + String(source.binding_ref().kind_name)
        + String("' DECLARES orientation=")
        + String(declared)
        + String(". A kind's orientation is declared data, not a default the")
        + String(" caller may overrule — it decides which execution hierarchy")
        + String(" the scan is routed to, so an override runs the scan on the")
        + String(" wrong executor. The declaration wins regardless; this is")
        + String(" refused rather than silently ignored. Fix the DECLARATION")
        + String(" in the kind's binding builder / descriptor, or drop the")
        + String(" argument and let it be derived.")
    )


# =============================================================================
# Join type constants
# =============================================================================

comptime JOIN_INNER: UInt8 = 0
comptime JOIN_LEFT: UInt8 = 1
comptime JOIN_RIGHT: UInt8 = 2
comptime JOIN_FULL: UInt8 = 3
comptime JOIN_SEMI: UInt8 = 4
comptime JOIN_ANTI: UInt8 = 5
comptime JOIN_CROSS: UInt8 = 6
# NOTE: there is no JOIN_SORT_MERGE join type (value 7 is retired).
# Sort-merge is an ALGORITHM choice, not a semantic join type -- see the
# `JoinAlgo` constants below. Callers: pass semantic JOIN_INNER with
# `algo_hint=JOIN_ALGO_SORT_MERGE` on JoinData (or via DataFrame.join's
# `algo=` kwarg).

# =============================================================================
# JoinAlgo constants -- physical join algorithm selection
# =============================================================================
#
# Orthogonal to JoinType. The optimizer / auto-select rule maps JOIN_ALGO_AUTO
# to a concrete algorithm based on cardinality + sortedness.

comptime JOIN_ALGO_AUTO: UInt8 = 0
comptime JOIN_ALGO_HASH: UInt8 = 1
comptime JOIN_ALGO_SORT_MERGE: UInt8 = 2


# =============================================================================
# ASOF join constants
# =============================================================================
#
# Strategy picks the match direction inside an equi-key group on the ASOF
# column. `by=[]` → single-group
# semantics (O(N*M)); `tolerance=AsofTolerance.none()` → unbounded match.

comptime ASOF_BACKWARD: UInt8 = 0   # last right row with right.ts <= left.ts
comptime ASOF_FORWARD: UInt8 = 1    # first right row with right.ts >= left.ts
comptime ASOF_NEAREST: UInt8 = 2    # smallest |left.ts - right.ts|; tie → backward

# Tolerance tag — opaque payload selector inside AsofTolerance.
comptime ASOF_TOL_NONE: UInt8 = 0
comptime ASOF_TOL_INT64: UInt8 = 1
comptime ASOF_TOL_FLOAT64: UInt8 = 2


@fieldwise_init
struct AsofTolerance(ImplicitlyCopyable, Movable):
    """Opaque tolerance envelope for ASOF matches (`|left.ts - right.ts| <= tol`).

    A tagged single struct rather than an optional enum, so the SDK surface
    has no sentinels. Constructors: `AsofTolerance.int64(v)`,
    `AsofTolerance.float64(v)`, `AsofTolerance.none()`.

    Tolerance comparison is inclusive (`<=`).
    The `int_val` / `float_val` fields are payload slots; only the one
    matching `tag` carries meaning.

    Copyable so SDK call sites can pass it by value without transfer
    gymnastics (payload is 24 B fixed-width).
    """
    var tag: UInt8       # ASOF_TOL_{NONE,INT64,FLOAT64}
    var int_val: Int64
    var float_val: Float64

    @staticmethod
    def none() -> AsofTolerance:
        """Unbounded — no tolerance check applied (default)."""
        return AsofTolerance(tag=ASOF_TOL_NONE, int_val=Int64(0), float_val=Float64(0.0))

    @staticmethod
    def int64(v: Int64) -> AsofTolerance:
        """Integer tolerance (for Int32/Int64 ASOF columns). Must be >= 0."""
        return AsofTolerance(tag=ASOF_TOL_INT64, int_val=v, float_val=Float64(0.0))

    @staticmethod
    def float64(v: Float64) -> AsofTolerance:
        """Float tolerance (for Float64 ASOF columns). Must be >= 0.0."""
        return AsofTolerance(tag=ASOF_TOL_FLOAT64, int_val=Int64(0), float_val=v)

    @always_inline
    def is_none(self) -> Bool:
        return self.tag == ASOF_TOL_NONE

    @always_inline
    def is_int64(self) -> Bool:
        return self.tag == ASOF_TOL_INT64

    @always_inline
    def is_float64(self) -> Bool:
        return self.tag == ASOF_TOL_FLOAT64


# =============================================================================
# ExprArray / AggExprArray — type aliases for Slab
# =============================================================================
#
# Mojo's List[T] requires T: Copyable. Expr and AggExpr are Movable-only
# (they own OwnedPointer children). Slab[T] provides the same
# growable-array semantics with only T: Movable required.
#
# Consumers import them as `from .logical_plan import ExprArray, AggExprArray`.
# =============================================================================

comptime ExprArray = Slab[Expr]
"""A list of `Expr`. `Expr` is Movable-not-Copyable, so this is NOT
`Copyable` — use `copy_expr_array` below for a deep clone."""


def copy_expr_array(imm exprs: ExprArray) raises -> ExprArray:
    """Deep-clone an `ExprArray` for ownership transfer.

    ⚠ `ExprArray` HAS NO `.copy()` AND THAT IS NOT AN OVERSIGHT. `Expr` is
    Movable, not Copyable — deliberately, because an expression tree owns
    `OwnedPointer` children and an implicit copy would be an unbounded deep
    clone at every binding. `Expr.copy()` is the explicit primitive; this walks
    it element-wise.

    ★ IT LIVES HERE, BESIDE THE ALIAS, SO THERE IS ONE COPY. A private copy
    per module is how a "deep clone" quietly becomes a shallow one somewhere.
    """
    var out = ExprArray()
    for i in range(len(exprs)):
        out.append(exprs[i].copy())
    return out^

comptime AggExprArray = Slab[AggExpr]


# =============================================================================
# CorrelatedSubquery kind constants
# =============================================================================
#
# ⚠ DECLARED IN `corr_subquery_data.mojo`; this import is the FACADE
# re-export, so `from komira_plan_ir.logical_plan import CORR_KIND_SCALAR`
# (and `CorrelatedSubqueryData`) resolves. They live there because `Expr`
# needs them and they are four `UInt8`s — nothing about them needs this
# module, and `expr.mojo` importing them from HERE would drag `LogicalPlan`'s
# whole closure under `Expr`.
#
# Discriminant for `CorrelatedSubqueryData.kind`. Selects the lowering shape
# that `flatten_dependent_joins` produces:
#   - CORR_KIND_EXISTS         → JOIN_SEMI
#   - CORR_KIND_NOT_EXISTS     → JOIN_ANTI
#   - CORR_KIND_SCALAR         → JOIN_LEFT + agg sink (Q17 shape)
#   - CORR_KIND_IN_CORRELATED  → JOIN_SEMI with the IN-list equi-key appended
#                                (Q20). See the `CorrelatedSubqueryData`
#                                docstring in `corr_subquery_data.mojo` for the
#                                full semantics narrative.

from komira_plan_expr.corr_subquery_data import (
    CorrelatedSubqueryData,
    BoxablePlan,
    CORR_SUBQ_PLAN_TYPE_TAG,
    CORR_KIND_EXISTS,
    CORR_KIND_NOT_EXISTS,
    CORR_KIND_SCALAR,
    CORR_KIND_IN_CORRELATED,
)


# =============================================================================
# Variant data structs live in logical_plan_variants.mojo.
#
# The `from .logical_plan_variants import (...)` below is BOTH the in-scope
# import (so the factory methods + tag-dispatch methods below can use the
# *Data structs) AND the FACADE re-export — a consumer may import
# `from komira_plan_ir.logical_plan import ScanData`.
#
# ⚠ `CorrelatedSubqueryData` IS NOT IN THIS LIST. It is imported above,
# from `corr_subquery_data.mojo`, because `expr.mojo` needs it and cannot reach
# anything that names `LogicalPlan`.
# =============================================================================

from komira_plan_ir.logical_plan_variants import (
    ScanData,
    FilterData,
    ProjectData,
    AggGroupTopK,
    AggregateData,
    JoinData,
    SortData,
    LimitData,
    DistinctData,
    TopNData,
    PartitionByData,
    PartitionTopNData,
    AsofJoinData,
    UnionData,
    ViewRefData,
    CseRefData,
    CastToVarcharData,
)


# =============================================================================
# LogicalPlan — the main plan tree node
# =============================================================================

struct LogicalPlan(Movable, Writable, BoxablePlan):
    """A node in the logical plan tree.

    Tagged struct with typed Optional variant data. Uses OwnedPointer[LogicalPlan]
    for recursive child references (like Rust's Box<LogicalPlan>). Same pattern
    as the Expr struct: only one Optional is populated at a time.

    Every node carries:
        tag: UInt8              -- node type discriminant
        output_schema: Schema   -- the schema of this node's output
    """

    var tag: UInt8
    var output_schema: Schema
    var _scan: Optional[OwnedPointer[ScanData]]
    var _filter: Optional[OwnedPointer[FilterData]]
    var _project: Optional[OwnedPointer[ProjectData]]
    var _aggregate: Optional[OwnedPointer[AggregateData]]
    var _join: Optional[OwnedPointer[JoinData]]
    var _sort: Optional[OwnedPointer[SortData]]
    var _limit: Optional[OwnedPointer[LimitData]]
    var _distinct: Optional[OwnedPointer[DistinctData]]
    var _topn: Optional[OwnedPointer[TopNData]]
    var _partition_by: Optional[OwnedPointer[PartitionByData]]
    var _partition_topn: Optional[OwnedPointer[PartitionTopNData]]
    var _asof_join: Optional[OwnedPointer[AsofJoinData]]
    var _union: Optional[OwnedPointer[UnionData]]
    var _view_ref: Optional[OwnedPointer[ViewRefData]]
    var _cse_ref: Optional[OwnedPointer[CseRefData]]
    var _cast_to_varchar: Optional[OwnedPointer[CastToVarcharData]]

    # --- Private constructor (all fields None) ---

    def __init__(out self, tag: UInt8, var schema: Schema):
        """Create a LogicalPlan with the given tag and output schema.
        All variant data is None."""
        self.tag = tag
        self.output_schema = schema^
        self._scan = None
        self._filter = None
        self._project = None
        self._aggregate = None
        self._join = None
        self._sort = None
        self._limit = None
        self._distinct = None
        self._topn = None
        self._partition_by = None
        self._partition_topn = None
        self._asof_join = None
        self._union = None
        self._view_ref = None
        self._cse_ref = None
        self._cast_to_varchar = None

    # =========================================================================
    # Factory methods
    # =========================================================================

    @staticmethod
    def scan(
        source_path: String,
        source_type: UInt8,
        var schema: Schema,
        var projection: Optional[List[String]] = None,
        var filter: Optional[Expr] = None,
        var row_count: Optional[Int] = None,
        var table_stats: Optional[TableStats] = None,
        var inline_batch: Optional[ArcPointer[RecordBatch]] = None,
    ) -> LogicalPlan:
        """Create a Scan node with an explicit schema (positional API).

        The entry point for call sites that pass
        `(source_path, source_type, schema, ...)`. Internally it
        constructs a `SourceVariant` from those args:

          - SOURCE_PARQUET: wrap path + schema in `ParquetSource`.
          - SOURCE_IN_MEMORY: build an empty-batch `InMemorySource` whose
            `name` field carries the registry handle (the engine-side
            `_compile_scan` resolves the batch via `registry.lookup(name)`).
          - SOURCE_NDJSON: a `JsonSource` (binding-backed, declares ROW).
          - otherwise (CSV): a `CsvSource` with the file's mtime.

        `scan_from_source(source: SourceVariant, ...)` is the canonical
        entry point — direct callers should prefer it.

        Args:
            source_path: File path or URI (PARQUET) or registry name
                (IN_MEMORY).
            source_type: One of SOURCE_PARQUET, SOURCE_CSV, etc.
            schema: The schema of the data source.
            projection: Optional column names to read.
            filter: Optional predicate for pushdown.
            row_count: Optional exact row count from source metadata
                (e.g. the Parquet footer). Used by
                the cost model for join build-side selection.
            table_stats: Optional source table statistics for the cost model.
            inline_batch: Accepted and IGNORED. Carry a batch by calling
                `scan_from_source(SourceVariant(
                InMemorySource.from_record_batch(...)))` instead.
        """
        # Build output schema: apply projection if present.
        # Use `field_at_unchecked`
        # to preserve Field metadata (tz, decimal (p,s), dict_index_type,
        # union_type_ids, flags, kv-metadata, nested children). The legacy
        # 3-arg Field(name, arrow_type, nullable) ctor zero-fills these slots.
        var out_schema: Schema
        if projection:
            var proj_names = projection.value().copy()
            var builder = SchemaBuilder()
            for pname in proj_names:
                # Find this column in the full schema
                for i in range(schema.num_columns()):
                    if schema.field_name(i) == pname:
                        builder.add_field(schema.field_at_unchecked(i))
                        break
            out_schema = builder.build()
        else:
            # Copy all fields from the source schema
            var builder = SchemaBuilder()
            for i in range(schema.num_columns()):
                builder.add_field(schema.field_at_unchecked(i))
            out_schema = builder.build()

        # Build the SourceVariant from the (path, type) args.
        var source: SourceVariant
        if source_type == SOURCE_PARQUET:
            var ps = ParquetSource(
                String(source_path),
                schema.copy(),
                Optional[String](None),
            )
            source = SourceVariant(ps^)
        elif source_type == SOURCE_IN_MEMORY:
            # IN_MEMORY: the InMemorySource carries an empty batch slab
            # plus the registry handle in its `name` field. Engine-side
            # `_compile_scan` resolves the actual batch via
            # `registry.lookup(name)`.
            #
            # `inline_batch` is IGNORED here: direct batch carrying goes
            # through `scan_from_source(
            # SourceVariant(InMemorySource.from_record_batch(...)))`.
            _ = inline_batch  # accepted and ignored
            var nm: Optional[String] = Optional(String(source_path))
            var sl = Slab[RecordBatch].create(0)
            var im = InMemorySource._from_record_batches_unchecked(sl^, schema.copy(), nm^)
            source = SourceVariant(im^)
        elif source_type == SOURCE_NDJSON:
            # NDJSON routes through the JsonSource arm. `ScanData.__init__`
            # derives `source_type = SOURCE_JSON` from `SOURCE_VARIANT_JSON`
            # (NOT SOURCE_NDJSON).
            #
            # ⚠ THIS ARM BUILDS A BINDING-BACKED VARIANT, AND ITS ANSWER IS
            # ROW: `komira.json` DECLARES `orientation = ROW` and the ctor
            # reads the declaration, so `LogicalPlan.scan(path, SOURCE_NDJSON,
            # ...)` yields SOURCE_KIND_ROW. Pinned by
            # `test_scan_binding_json_arm.mojo
            # :test_the_legacy_ndjson_factory_now_agrees_with_the_kind`.
            var js = JsonSource(String(source_path), schema.copy())
            source = SourceVariant(js^)
        else:
            # ★ CSV BUILDS A `CsvSource`, NOT A `ParquetSource`. A CSV read
            # (`ctx.read_csv_row_streaming`, `CsvReader.build_scan_plan`, SQL's
            # `read_csv(...)`) must produce a scan whose SourceVariant says
            # CSV, whose wire encoding names the right source kind, and which
            # carries the mtime and the quote dialect — and whose ROW layout
            # comes from `komira.csv`'s own DECLARED orientation rather than
            # from a caller threading `SOURCE_KIND_ROW` by hand.
            #
            # ⚠ THE MTIME IS STATTED HERE, AND IT IS NOT COSMETIC.
            # `komira.csv` declares `SNAPSHOT_PINNED` with the file mtime AS
            # its snapshot token, so a leaf built with `mtime_ns=0` would claim
            # a pinned snapshot it does not have and could serve a compiled plan
            # against a rewritten file. `FileIdentity.stat_path` NEVER RAISES —
            # a path that does not exist yields the invalid identity, whose
            # `mtime_ns` is 0 — so callers that name a fixture path they never
            # create keep working.
            #
            # ⚠ THE DIALECT IS THE DEFAULT HERE, ON PURPOSE. This factory's
            # signature carries no options, so it cannot honour a non-default
            # `delimiter` / `has_header` / `quote_style_tag` — and dropping an
            # option is the one thing `sql_tvf_bind`'s module note forbids. A
            # caller with options therefore calls `scan_from_source` with a
            # fully-populated `CsvSource` instead; `tvf_relation_scan` is that
            # caller and is the reason `read_csv('f', delim='|')` has a
            # plan identity that differs from `read_csv('f')`.
            var mtime = FileIdentity.stat_path(String(source_path)).mtime_ns
            var cs = CsvSource(
                String(source_path),
                schema.copy(),
                mtime_ns=UInt64(mtime),
            )
            source = SourceVariant(cs^)

        # ⭐ THIS FACTORY STATES NO LAYOUT AT ALL, SO IT CANNOT CONTRADICT A
        # KIND'S DECLARATION BY CONSTRUCTION — there is no value here to edit.
        # `derive_source_layout` answers.
        var plan = LogicalPlan(PLAN_SCAN, out_schema^)
        var scan_schema: Optional[Schema] = schema^
        plan._scan = OwnedPointer(ScanData(source^, scan_schema^, projection^, filter^, row_count^, table_stats^))
        return plan^

    @staticmethod
    def scan_from_source(
        var source: SourceVariant,
        var schema: Schema,
        var projection: Optional[List[String]] = None,
        var filter: Optional[Expr] = None,
        var row_count: Optional[Int] = None,
        var table_stats: Optional[TableStats] = None,
        source_kind: UInt8 = SOURCE_KIND_UNSET,
    ) raises -> LogicalPlan:
        """Canonical factory: build a Scan node from a SourceVariant.

        The output schema is derived from the explicit schema + projection
        (same shape as the positional `scan(...)` factory). Use this for new
        code.

        `source_kind` is threaded so an optimizer pushdown that REBUILDS a
        scan (e.g. `optimizer_filter.push_predicates_down` merging a filter
        into the scan) can PRESERVE a stated layout.

        ⚠ THE DEFAULT IS `SOURCE_KIND_UNSET`, NOT `SOURCE_KIND_COLUMNAR`.
        With a COLUMNAR default, "the caller said COLUMNAR" and "the caller
        said nothing" would be the same byte, which would reduce a binding's
        DECLARED `orientation` to a default it could be talked out of.
        Unset means DERIVE; a stated value that contradicts a binding-backed
        kind's declaration RAISES rather than winning silently. Builders over
        a ROW-declaring kind (`engine_context.read_avro_row_streaming`,
        `AvroReader.build_scan_plan`, the JSONL builders) pass nothing and
        derive it — the declaration REPLACES a ladder rather than sitting
        beside one.

        ⛔ THE ONLY IN-TREE CALLER THAT STATES A LAYOUT IS THE PLAN WIRE
        DECODER (`komira_plan_wire`'s `_plan_from_wire` PLAN_SCAN arm), which
        re-states the `WireScanNode.source_kind` it decoded. ⚠ THAT ARGUMENT IS
        LOAD-BEARING AND THE PARAMETER MAY NOT BE DELETED FOR IT: on a
        binding-backed leaf the refusal below is what catches a wire payload
        lying about a kind's declared orientation, and on a NON-binding-backed
        leaf (parquet, in-memory) the ctor's `else` KEEPS the decoded value, so
        a forged byte changes the decoded plan. Both arms are pinned by the
        plan-wire round-trip tests in komira_plan_wire.
        """
        # THE ORIENTATION REFUSAL. This is the caller-facing
        # factory, so it is where a caller learns that it contradicted the kind.
        # `ScanData` ENFORCES the rule (it ignores `source_kind` for a
        # binding-backed source); this REPORTS it.
        #
        # ⚠ NOT "THE ONLY WAY A BINDING-BACKED SOURCE REACHES A PLAN": the
        # positional `scan()` factory's `SOURCE_NDJSON` arm builds one too, and
        # does not call this. That door is closed on the other side instead —
        # it states NO `source_kind`, so it cannot contradict a declaration by
        # construction.
        _require_orientation_agreement(source, source_kind)
        # Use `field_at_unchecked`
        # to preserve Field metadata — see `scan` factory above.
        var out_schema: Schema
        if projection:
            var proj_names = projection.value().copy()
            var builder = SchemaBuilder()
            for pname in proj_names:
                for i in range(schema.num_columns()):
                    if schema.field_name(i) == pname:
                        builder.add_field(schema.field_at_unchecked(i))
                        break
            out_schema = builder.build()
        else:
            var builder = SchemaBuilder()
            for i in range(schema.num_columns()):
                builder.add_field(schema.field_at_unchecked(i))
            out_schema = builder.build()

        var plan = LogicalPlan(PLAN_SCAN, out_schema^)
        var scan_schema: Optional[Schema] = schema^
        plan._scan = OwnedPointer(ScanData(source^, scan_schema^, projection^, filter^, row_count^, table_stats^, source_kind))
        return plan^

    @staticmethod
    def filter(
        var predicate: Expr,
        var child: LogicalPlan,
    ) -> LogicalPlan:
        """Create a Filter node.

        Output schema is identical to child schema (filter preserves columns).
        The predicate must evaluate to Bool -- verified during plan validation.

        The typed-UDF variant of this factory is
        `filter_with_udf` — it takes a UdfData snapshot in addition to a
        (placeholder) predicate. The ordinary `Expr`-only path is unchanged.
        """
        # Copy child's output schema for this node's output.
        # Use `field_at_unchecked`
        # to preserve Field metadata (tz, decimal (p,s), dict_index_type,
        # union_type_ids, flags, kv-metadata, nested children).
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_FILTER, out_schema^)
        plan._filter = OwnedPointer(FilterData(predicate^, child^))
        return plan^

    @staticmethod
    def filter_with_udf(
        var predicate: Expr,
        var child: LogicalPlan,
        var udf: OwnedPointer[UdfData],
    ) -> LogicalPlan:
        """Create a Filter node carrying a typed-UDF `UdfData` payload.

        Used by `df.filter_udf[F: FilterFn](f)` on both DataFrame types. The
        `predicate` is typically a placeholder `lit(true)` — the operator
        build driver routes through the UDF dispatch when
        `udf.is_filter()` is True. The UdfData payload is type-erased; `F` is
        recovered at operator-build time via `udf.operator_factory_id` +
        `udf.call_site_salt` against the comptime UDF pack threaded down
        from the SDK call site through `lower_untyped_udf_segment[F]`.
        Output schema = child schema (filter preserves columns).
        """
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_FILTER, out_schema^)
        plan._filter = OwnedPointer(
            FilterData(predicate^, child^, Optional(udf^))
        )
        return plan^

    @staticmethod
    def project(
        var exprs: ExprArray,
        var child: LogicalPlan,
        is_cse_introduced: Bool = False,
    ) -> LogicalPlan:
        """Create a Project node.

        Output schema is derived from the expression list:
        - ColRef("x") -> same field as x in child schema
        - Alias(expr, "name") -> Field named "name"
        - Literal -> auto-generated name
        - BinaryOp -> auto-generated name

        The typed-UDF variant of this factory is
        `project_with_udf` — it takes a UdfData snapshot in addition to the
        Expr list. The ordinary `Expr`-only path is unchanged.
        """
        var builder = SchemaBuilder()
        for i in range(len(exprs)):
            var field = _infer_expr_field(exprs[i], child.output_schema)
            builder.add_field(field^)
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_PROJECT, out_schema^)
        plan._project = OwnedPointer(ProjectData(exprs^, child^, is_cse_introduced))
        return plan^

    @staticmethod
    def project_with_udf(
        var exprs: ExprArray,
        var child: LogicalPlan,
        var udf: OwnedPointer[UdfData],
        is_cse_introduced: Bool = False,
    ) -> LogicalPlan:
        """Create a Project node carrying a typed-UDF `UdfData`
        payload (the `df.map_udf[M: MapFn](m)` path).

        Output schema is derived from `exprs` (the same way as `project` —
        callers typically pass `col_ref` placeholders matching
        `M.OutputSchema` so downstream schema validation and EXPLAIN see
        the post-UDF columns). The operator-build driver routes
        execution through the UDF when `udf.is_map()` is True;
        `M` is recovered at operator-build time via
        `udf.operator_factory_id` + `udf.call_site_salt`.
        """
        var builder = SchemaBuilder()
        for i in range(len(exprs)):
            var field = _infer_expr_field(exprs[i], child.output_schema)
            builder.add_field(field^)
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_PROJECT, out_schema^)
        plan._project = OwnedPointer(
            ProjectData(exprs^, child^, is_cse_introduced, Optional(udf^))
        )
        return plan^

    @staticmethod
    def union(
        var children: List[OwnedPointer[LogicalPlan]],
        var output_schema: Schema,
    ) -> LogicalPlan:
        """Create a UNION ALL node.

        `output_schema` is the common schema of every branch — the caller
        is responsible for ensuring every child advertises this schema
        (the engine does not coerce). `children` must be non-empty.

        The caller is `plan_compiler._lower_multi_file_parquet_scan`,
        which builds one branch per parquet file (Hive: each branch wraps
        the per-file scan in a literal `Project` adding the partition cols).
        """
        var plan = LogicalPlan(PLAN_UNION, output_schema^)
        plan._union = OwnedPointer(UnionData(children^))
        return plan^

    @staticmethod
    def view_ref(var view_name: String, var output_schema: Schema) -> LogicalPlan:
        """Create a lazy view-reference node.

        Returns a single-node plan: a `PLAN_VIEW_REF` leaf carrying the
        view's name + a snapshot of its output schema. `ctx.view(handle)`
        is the only producer. The `view_resolution_pass` compiler sub-pass
        replaces this node with the registered view's expanded plan during
        `optimize()` (pass-1, before `flatten_dependent_joins` and before
        the structural_hash is taken).

        Args:
            view_name: The registered view's name. Caller (`ctx.view`)
                guarantees it is non-empty + present in the registry at
                resolution time.
            output_schema: A snapshot of the view's output schema, taken
                at `ctx.view(handle)` time.
        """
        var schema_for_node = output_schema.copy()
        var plan = LogicalPlan(PLAN_VIEW_REF, schema_for_node^)
        plan._view_ref = OwnedPointer(ViewRefData(view_name^, output_schema^))
        return plan^

    @staticmethod
    def cse_ref(canonical_hash: UInt64, var output_schema: Schema) -> LogicalPlan:
        """Create a CSE-reference leaf node.

        Returns a single-node plan: a `PLAN_CSE_REF` leaf carrying the
        canonical subtree's `structural_hash` + a snapshot of its output
        schema. The ONLY producer is `plan_cse.plan_cse_eliminate` (the
        plan-level CSE rewrite); the ONLY consumer is `plan_compiler`'s
        `_compile_node` arm. `structural_hash()` on the returned plan
        returns `canonical_hash` (so re-CSE is idempotent — see
        `CseRefData` docstring).

        Args:
            canonical_hash: `structural_hash()` of the canonical occurrence.
            output_schema: Snapshot of the canonical subtree's output schema.
        """
        var schema_for_node = output_schema.copy()
        var plan = LogicalPlan(PLAN_CSE_REF, schema_for_node^)
        plan._cse_ref = OwnedPointer(CseRefData(canonical_hash, output_schema^))
        return plan^

    @staticmethod
    def cast_to_varchar(var child: LogicalPlan) -> LogicalPlan:
        """Create a `PLAN_CAST_TO_VARCHAR` node wrapping `child`.

        Output schema: per-column STRING-typed mirror of `child.output_schema`
        — every column carries its original name (and nullability) but its
        `ArrowType` is replaced with `ArrowType.STRING`. The rewrite makes
        the cast SHAPE visible to schema-dependent passes (sink columnar
        format negotiation, plan_display, EXPLAIN), even though the actual
        runtime cast fires at engine-execute time through `CastToVarcharOp`.

        Producer: `cast_to_varchar_insert.insert_cast_if_text_output`.

        Args:
            child: The inner plan whose output is to be cast column-by-column
                to UTF-8 STRING. Move-taken; the node owns the child via
                `OwnedPointer`.
        """
        var builder = SchemaBuilder()
        var num_cols = child.output_schema.num_columns()
        for i in range(num_cols):
            var name = child.output_schema.field_name(i)
            var nullable = child.output_schema.field_at_unchecked(i).nullable
            builder.add_field(Field(name, ArrowType.STRING, nullable))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_CAST_TO_VARCHAR, out_schema^)
        plan._cast_to_varchar = OwnedPointer(CastToVarcharData(child^))
        return plan^

    @staticmethod
    def aggregate(
        var group_by: ExprArray,
        var agg_exprs: AggExprArray,
        var child: LogicalPlan,
    ) -> LogicalPlan:
        """Create an Aggregate node.

        Output schema: [group_key_columns...] + [builtin_agg_output_columns...]

        The typed-UDF variant of this factory is
        `aggregate_with_udf` — it takes a UdfData snapshot in addition to
        group_by + agg_exprs. The ordinary `AggExpr`-only path is unchanged.
        """
        var builder = SchemaBuilder()
        # Track emitted output names so unaliased same-func
        # aggregates (`sum(a), sum(b)` -> both "sum") are disambiguated to
        # "sum", "sum_1" instead of silently colliding (and dropping on the
        # parquet round-trip). See `_disambiguate_field`.
        var seen_names = List[String]()
        # Group-by columns
        for i in range(len(group_by)):
            var field = _infer_expr_field(group_by[i], child.output_schema)
            builder.add_field(_disambiguate_field(seen_names, field^))
        # Builtin aggregate output columns
        for i in range(len(agg_exprs)):
            var field = _infer_agg_field(agg_exprs[i], child.output_schema)
            builder.add_field(_disambiguate_field(seen_names, field^))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_AGGREGATE, out_schema^)
        plan._aggregate = OwnedPointer(AggregateData(group_by^, agg_exprs^, child^, None))
        return plan^

    @staticmethod
    def aggregate_with_udf(
        var group_by: ExprArray,
        var agg_exprs: AggExprArray,
        var child: LogicalPlan,
        var udf: OwnedPointer[UdfData],
    ) -> LogicalPlan:
        """Create an Aggregate node carrying a typed-UDF `UdfData`
        payload (the `df.group_by(keys).agg_udf[A: AggFn](a)` path).

        Output schema = `group_by` columns + `agg_exprs` outputs +
        `udf.output_columns`. The operator-build driver routes execution
        through the UDF when `udf.is_agg()` is True; `A` is
        recovered at operator-build time via `udf.operator_factory_id` +
        `udf.call_site_salt`. `agg_exprs` may be empty (the UDF produces
        all aggregations) — the builder folds `udf.output_columns` into
        the output schema in that case.
        """
        var builder = SchemaBuilder()
        # Disambiguate duplicate output names (see
        # `_disambiguate_field`); same scheme as the non-UDF `aggregate`.
        var seen_names = List[String]()
        # Group-by columns
        for i in range(len(group_by)):
            var field = _infer_expr_field(group_by[i], child.output_schema)
            builder.add_field(_disambiguate_field(seen_names, field^))
        # Builtin aggregate output columns
        for i in range(len(agg_exprs)):
            var field = _infer_agg_field(agg_exprs[i], child.output_schema)
            builder.add_field(_disambiguate_field(seen_names, field^))
        # UDF output columns (from the snapshotted A.OutputSchema in UdfData).
        # Map the dtag UInt8 back to ArrowType via the helper in `udf_data.mojo`
        # (DATE32/DATE64/TIMESTAMP map to INT32/INT64 — the UDF dtag space has
        # no dedicated date/timestamp Arrow types; the operator-build comptime
        # assert against A.OutputSchema is the real correctness gate).
        for i in range(len(udf[].output_columns)):
            var col_name = udf[].output_columns[i][0]
            var col_dtag = udf[].output_columns[i][1]
            builder.add_field(Field(col_name, arrow_type_of_dtag(col_dtag), True))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_AGGREGATE, out_schema^)
        plan._aggregate = OwnedPointer(
            AggregateData(group_by^, agg_exprs^, child^, None, Optional(udf^))
        )
        return plan^

    @staticmethod
    def join(
        var left: LogicalPlan,
        var right: LogicalPlan,
        var left_on: List[String],
        var right_on: List[String],
        join_type: UInt8,
        algo_hint: UInt8 = JOIN_ALGO_AUTO,
        var residual: Optional[OwnedPointer[Expr]] = None,
    ) -> LogicalPlan:
        """Create a Join node.

        For INNER/LEFT/RIGHT/FULL: output schema = left + right.
        For SEMI/ANTI: output schema = left only.

        `algo_hint` is orthogonal to `join_type` -- it picks the physical
        kernel (AUTO / HASH / SORT_MERGE).

        `residual` carries the non-EQ / complex part of a
        join `predicate=` expression. When the DataFrame `predicate=` API
        is used, the raw (side-qualified) predicate is stashed here with
        `left_on`/`right_on` empty; the `join_predicate_decompose`
        optimizer pass then lifts equi-conjuncts into `left_on`/`right_on`
        and rewrites the surviving residual to plain col-refs. `None` for
        ordinary pure-EQ joins.
        """
        # ⚠ CONTRACT-BOUND: this output-schema construction (left cols; right
        # cols only for non-SEMI/ANTI; right-side name collisions get a
        # `_right` suffix; the NULL-supplying side of an outer join forced
        # nullable) is mirrored at comptime in `komira_plan_expr/
        # typed_schema.mojo` (`join_out_schema`) and re-derived by
        # `schema_propagation._infer_join_schema`. Keep the three in sync.
        # Use `field_at_unchecked`
        # to preserve Field metadata on both sides. Right-side collision
        # rename uses the clone-then-mutate pattern.
        #
        # ⛔ NULLABILITY IS PART OF THE CONTRACT. A LEFT join emits every left
        # row and fills the right columns of an unmatched one with NULL; RIGHT
        # is the mirror image and FULL does both. Copying those fields
        # verbatim left a non-nullable right column `nullable=False` after a
        # LEFT join while the executor writes NULLs into it (komira#960).
        # `asof_join` below forces its right side for the same reason.
        # Falsifier: `test_outer_join_nullability.mojo`.
        var left_nulls = join_type == JOIN_RIGHT or join_type == JOIN_FULL
        var right_nulls = join_type == JOIN_LEFT or join_type == JOIN_FULL
        var builder = SchemaBuilder()
        # Always include left-side columns
        for i in range(left.output_schema.num_columns()):
            var lf = left.output_schema.field_at_unchecked(i)
            if left_nulls:
                lf.nullable = True
            builder.add_field(lf^)
        # For non-semi/anti joins, also include right-side columns
        if join_type != JOIN_SEMI and join_type != JOIN_ANTI:
            for i in range(right.output_schema.num_columns()):
                # Prefix with "right." if name collision with left side
                var rname = right.output_schema.field_name(i)
                var has_collision = False
                for j in range(left.output_schema.num_columns()):
                    if left.output_schema.field_name(j) == rname:
                        has_collision = True
                        break
                var rf = right.output_schema.field_at_unchecked(i)
                if has_collision:
                    rf.name = rname + "_right"
                if right_nulls:
                    rf.nullable = True
                builder.add_field(rf^)
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_JOIN, out_schema^)
        plan._join = OwnedPointer(
            JoinData(left^, right^, left_on^, right_on^, join_type, algo_hint, residual^)
        )
        return plan^

    @staticmethod
    def sort(
        var keys: List[String],
        var descending: List[Bool],
        var child: LogicalPlan,
        var nulls_first: Optional[List[Bool]] = None,
    ) -> LogicalPlan:
        """Create a Sort node. Output schema = child schema.

        `nulls_first` is an optional per-key NULL
        placement override (SQL `NULLS FIRST/LAST`). None (default)
        takes `null_order_policy.derived_nulls_first` (NULLS LAST, both
            directions).
        """
        # Preserve Field metadata.
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_SORT, out_schema^)
        plan._sort = OwnedPointer(SortData(keys^, descending^, child^, nulls_first^))
        return plan^

    @staticmethod
    def limit(n: Int, var child: LogicalPlan, offset: Int = 0) -> LogicalPlan:
        """Create a Limit node. Output schema = child schema.

        `offset` (default 0) is the engine RANGE primitive: emit rows
        `[offset, offset + n)` of the child's output order. `offset == 0` is the
        plain first-`n` LIMIT.
        """
        # Preserve Field metadata.
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_LIMIT, out_schema^)
        plan._limit = OwnedPointer(LimitData(n, child^, offset=offset))
        return plan^

    @staticmethod
    def range_(offset: Int, n: Int, var child: LogicalPlan) -> LogicalPlan:
        """Create a RANGE node — rows `[offset, offset + n)` of child order.

        Named `range_` (trailing underscore) to avoid shadowing the builtin
        `range`. Sugar over `limit(n, child, offset=offset)`; the plan carries
        the window on the same PLAN_LIMIT node.
        """
        return LogicalPlan.limit(n, child^, offset=offset)

    @staticmethod
    def distinct(var columns: Optional[List[String]], var child: LogicalPlan) -> LogicalPlan:
        """Create a Distinct node. Output schema = child schema."""
        # Preserve Field metadata.
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_DISTINCT, out_schema^)
        plan._distinct = OwnedPointer(DistinctData(columns^, child^))
        return plan^

    @staticmethod
    def topn(
        var keys: List[String],
        var descending: List[Bool],
        n: Int,
        var child: LogicalPlan,
        var nulls_first: Optional[List[Bool]] = None,
    ) -> LogicalPlan:
        """Create a TopN node (fused Sort + Limit). Output schema = child schema.

        `nulls_first` is an optional per-key NULL
        placement override; None (default) takes
            `null_order_policy.derived_nulls_first` (NULLS LAST, both
        DESC->NULLS LAST.
        """
        # Preserve Field metadata.
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_TOPN, out_schema^)
        plan._topn = OwnedPointer(TopNData(keys^, descending^, n, child^, nulls_first^))
        return plan^

    @staticmethod
    def partition_by(
        var partition_keys: List[String],
        var order_keys: List[String],
        var descending: List[Bool],
        var partition_exprs: List[PartitionExpr],
        var child: LogicalPlan,
    ) raises -> LogicalPlan:
        """Create a PartitionBy (window function) node.

        Output schema = child schema + one column per partition expression.
        Row count is preserved: every input row gets the computed window
        function values appended.
        """
        # Preserve child Field
        # metadata on the pass-through portion. Appended window-fn Fields
        # use `partition_expr_output_field` (separate helper, not in scope).
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        for i in range(len(partition_exprs)):
            var field = partition_expr_output_field(
                partition_exprs[i], child.output_schema, i
            )
            builder.add_field(field^)
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_PARTITION_BY, out_schema^)
        plan._partition_by = OwnedPointer(PartitionByData(
            partition_keys^, order_keys^, descending^, partition_exprs^, child^
        ))
        return plan^

    @staticmethod
    def partition_topn(
        var partition_keys: List[String],
        var sort_keys: List[String],
        var descending: List[Bool],
        k: Int,
        var child: LogicalPlan,
        func: UInt8 = 0,  # PF_ROW_NUMBER default
        over_fetch_k: Int = -1,  # -1 sentinel = auto-derive from k
        var output_rank_col_name: Optional[String] = None,
    ) -> LogicalPlan:
        """Create a PartitionTopN node.

        Output schema = child schema (no new columns when
        `output_rank_col_name` is None; the kernel selects existing rows).
        When `output_rank_col_name = Some(name)`, the output schema is
        extended with an Int64 column carrying the rank value.

        `func` (PF_ROW_NUMBER vs PF_RANK) and `over_fetch_k` (per-partition
        heap capacity = k + tie-buffer for RANK) default to the ROW_NUMBER
        shape. The `fuse_partition_topn` optimizer pass sets these explicitly
        when emitting a fused RANK node.

        `output_rank_col_name` lets
        downstream Sort / Project / Filter operators that reference the
        synthetic rk/rn column can resolve it post-fusion. When set, the
        engine kernel emits an additional Int64 column holding the rank
        value per surviving row.
        """
        # Preserve child Field
        # metadata on the pass-through portion. The synthetic rank Field
        # below is INTENTIONALLY constructed via the 3-arg ctor (kernel
        # output column with no upstream metadata to propagate).
        var builder = SchemaBuilder()
        for i in range(child.output_schema.num_columns()):
            builder.add_field(child.output_schema.field_at_unchecked(i))
        # When `output_rank_col_name` is Some, append an
        # Int64 field for the rank/row_number value the kernel will emit.
        if output_rank_col_name:
            builder.add_field(Field(
                output_rank_col_name.value(),
                ArrowType.INT64,
                False,
            ))
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_PARTITION_TOPN, out_schema^)
        plan._partition_topn = OwnedPointer(PartitionTopNData(
            partition_keys^, sort_keys^, descending^, k, child^,
            func, over_fetch_k, output_rank_col_name^,
        ))
        return plan^

    @staticmethod
    def asof_join(
        var left: LogicalPlan,
        var right: LogicalPlan,
        var left_keys: List[String],
        var right_keys: List[String],
        var left_asof: String,
        var right_asof: String,
        strategy: UInt8,
        tolerance: AsofTolerance,
        var left_sort_keys: List[String] = List[String](),
        var left_sort_desc: List[Bool] = List[Bool](),
        var right_sort_keys: List[String] = List[String](),
        var right_sort_desc: List[Bool] = List[Bool](),
    ) -> LogicalPlan:
        """Create an AsofJoin node (time-series "as-of" left join).

        Output schema = left columns (nullability preserved) + right columns
        (all nullable, left-join semantics). Name collisions on the right
        side get a `_right` suffix. The rules-of-the-road:

        * `left_keys` / `right_keys`: parallel lists of equi-keys (the `by`
          columns). Same length. May both be empty = single-group semantics
          (O(N*M)).
        * `left_asof` / `right_asof`: single ASOF column per side. Types
          must match (Int32, Int64, or Float64).
        * `strategy`: ASOF_BACKWARD | ASOF_FORWARD | ASOF_NEAREST.
        * `tolerance`: AsofTolerance (use `.none()` for unbounded).
        * `*_sort_keys` / `*_sort_desc`: if non-empty, input is already
          sorted on `(equi_keys..., asof)` ascending — skip the sort phase.
        """
        # Preserve Field
        # metadata on both sides. Right-side collision rename + forced
        # nullable=True (left-join contract) use the clone-then-mutate
        # pattern (`_build_join_output_schema_outer`).
        var builder = SchemaBuilder()
        # Left columns: preserve as-is.
        for i in range(left.output_schema.num_columns()):
            builder.add_field(left.output_schema.field_at_unchecked(i))
        # Right columns: force nullable (left-join semantics always emits
        # every left row; right side may be NULL when no match).
        for i in range(right.output_schema.num_columns()):
            var rname = right.output_schema.field_name(i)
            var has_collision = False
            for j in range(left.output_schema.num_columns()):
                if left.output_schema.field_name(j) == rname:
                    has_collision = True
                    break
            var rf = right.output_schema.field_at_unchecked(i)
            if has_collision:
                rf.name = rname + "_right"
            rf.nullable = True   # always nullable on right -- left-join contract
            builder.add_field(rf^)
        var out_schema = builder.build()
        var plan = LogicalPlan(PLAN_ASOF_JOIN, out_schema^)
        plan._asof_join = OwnedPointer(AsofJoinData(
            left_keys^, right_keys^,
            left_asof^, right_asof^,
            strategy, tolerance,
            left_sort_keys^, left_sort_desc^,
            right_sort_keys^, right_sort_desc^,
            left^, right^,
        ))
        return plan^

    # =========================================================================
    # Type checks
    # =========================================================================

    @always_inline
    def is_scan(self) -> Bool:
        return self.tag == PLAN_SCAN

    @always_inline
    def is_filter(self) -> Bool:
        return self.tag == PLAN_FILTER

    @always_inline
    def is_project(self) -> Bool:
        return self.tag == PLAN_PROJECT

    @always_inline
    def is_aggregate(self) -> Bool:
        return self.tag == PLAN_AGGREGATE

    @always_inline
    def is_join(self) -> Bool:
        return self.tag == PLAN_JOIN

    @always_inline
    def is_sort(self) -> Bool:
        return self.tag == PLAN_SORT

    @always_inline
    def is_limit(self) -> Bool:
        return self.tag == PLAN_LIMIT

    @always_inline
    def is_distinct(self) -> Bool:
        return self.tag == PLAN_DISTINCT

    @always_inline
    def is_topn(self) -> Bool:
        return self.tag == PLAN_TOPN

    @always_inline
    def is_partition_by(self) -> Bool:
        return self.tag == PLAN_PARTITION_BY

    @always_inline
    def is_partition_topn(self) -> Bool:
        return self.tag == PLAN_PARTITION_TOPN

    @always_inline
    def is_asof_join(self) -> Bool:
        return self.tag == PLAN_ASOF_JOIN

    def is_union(self) -> Bool:
        return self.tag == PLAN_UNION

    def is_view_ref(self) -> Bool:
        return self.tag == PLAN_VIEW_REF

    def is_cse_ref(self) -> Bool:
        return self.tag == PLAN_CSE_REF

    @always_inline
    def is_cast_to_varchar(self) -> Bool:
        return self.tag == PLAN_CAST_TO_VARCHAR

    # =========================================================================
    # Typed-UDF presence + kind predicates. The three node types that can
    # carry a UDF are FILTER / PROJECT / AGGREGATE; all others return
    # False. `udf_method_kind` returns the UdfData kind tag
    # (`UDF_KIND_{MAP,FILTER,AGG}`) and is only meaningful when
    # `has_udf()` is True (returns 255 / DTAG_UNKNOWN otherwise).
    # =========================================================================

    @always_inline
    def has_udf(self) -> Bool:
        """True iff this plan node carries a typed-UDF UdfData payload (the
        `.filter_udf` / `.map_udf` / `.agg_udf` path)."""
        if self.tag == PLAN_FILTER and self._filter:
            return self._filter.value()[].has_udf()
        elif self.tag == PLAN_PROJECT and self._project:
            return self._project.value()[].has_udf()
        elif self.tag == PLAN_AGGREGATE and self._aggregate:
            return self._aggregate.value()[].has_udf()
        return False

    @always_inline
    def udf_method_kind(self) -> UInt8:
        """Return the UdfData kind tag (`UDF_KIND_MAP=0` / `UDF_KIND_FILTER=1` /
        `UDF_KIND_AGG=2`) when `has_udf()` is True; 255 (DTAG_UNKNOWN
        sentinel) otherwise. Consumed by row_mode dispatch."""
        if self.tag == PLAN_FILTER and self._filter and self._filter.value()[].has_udf():
            return self._filter.value()[].udf.value()[].kind
        elif self.tag == PLAN_PROJECT and self._project and self._project.value()[].has_udf():
            return self._project.value()[].udf.value()[].kind
        elif self.tag == PLAN_AGGREGATE and self._aggregate and self._aggregate.value()[].has_udf():
            return self._aggregate.value()[].udf.value()[].kind
        return UInt8(255)

    # =========================================================================
    # Accessor methods
    # =========================================================================

    @always_inline
    def scan_data_ref(self) -> ref [origin_of(self._scan.value()[])] ScanData:
        """Get a reference to the ScanData. Requires tag == PLAN_SCAN."""
        return self._scan.value()[]

    @always_inline
    def filter_data_ref(self) -> ref [origin_of(self._filter.value()[])] FilterData:
        """Get a reference to the FilterData. Requires tag == PLAN_FILTER."""
        return self._filter.value()[]

    @always_inline
    def project_data_ref(self) -> ref [origin_of(self._project.value()[])] ProjectData:
        """Get a reference to the ProjectData. Requires tag == PLAN_PROJECT."""
        return self._project.value()[]

    @always_inline
    def aggregate_data_ref(self) -> ref [origin_of(self._aggregate.value()[])] AggregateData:
        """Get a reference to the AggregateData. Requires tag == PLAN_AGGREGATE."""
        return self._aggregate.value()[]

    def set_estimated_groups(mut self, var v: Optional[Int]):
        """Pre-populate the plan-time group-count estimate on this
        node. Called by `precompute_aggregate_estimates` BEFORE
        `compile_plan` runs. No-op for non-AGG / non-DISTINCT tags.

        Plan-compile reads this via
        `_estimate_cardinality_with_precomputed`; when set, the heuristic
        is bypassed entirely.
        """
        if self.tag == PLAN_AGGREGATE and self._aggregate:
            self._aggregate.value()[].estimated_groups = v^
        elif self.tag == PLAN_DISTINCT and self._distinct:
            self._distinct.value()[].estimated_groups = v^

    @always_inline
    def join_data_ref(self) -> ref [origin_of(self._join.value()[])] JoinData:
        """Get a reference to the JoinData. Requires tag == PLAN_JOIN."""
        return self._join.value()[]

    @always_inline
    def sort_data_ref(self) -> ref [origin_of(self._sort.value()[])] SortData:
        """Get a reference to the SortData. Requires tag == PLAN_SORT."""
        return self._sort.value()[]

    @always_inline
    def limit_data_ref(self) -> ref [origin_of(self._limit.value()[])] LimitData:
        """Get a reference to the LimitData. Requires tag == PLAN_LIMIT."""
        return self._limit.value()[]

    @always_inline
    def distinct_data_ref(self) -> ref [origin_of(self._distinct.value()[])] DistinctData:
        """Get a reference to the DistinctData. Requires tag == PLAN_DISTINCT."""
        return self._distinct.value()[]

    @always_inline
    def topn_data_ref(self) -> ref [origin_of(self._topn.value()[])] TopNData:
        """Get a reference to the TopNData. Requires tag == PLAN_TOPN."""
        return self._topn.value()[]

    @always_inline
    def partition_by_data_ref(self) -> ref [origin_of(self._partition_by.value()[])] PartitionByData:
        """Get a reference to the PartitionByData. Requires tag == PLAN_PARTITION_BY."""
        return self._partition_by.value()[]

    @always_inline
    def partition_topn_data_ref(self) -> ref [origin_of(self._partition_topn.value()[])] PartitionTopNData:
        """Get a reference to the PartitionTopNData. Requires tag == PLAN_PARTITION_TOPN."""
        return self._partition_topn.value()[]

    @always_inline
    def asof_join_data_ref(self) -> ref [origin_of(self._asof_join.value()[])] AsofJoinData:
        """Get a reference to the AsofJoinData. Requires tag == PLAN_ASOF_JOIN."""
        return self._asof_join.value()[]

    def union_data_ref(self) -> ref [origin_of(self._union.value()[])] UnionData:
        """Get a reference to the UnionData. Requires tag == PLAN_UNION."""
        return self._union.value()[]

    def view_ref_data_ref(self) -> ref [origin_of(self._view_ref.value()[])] ViewRefData:
        """Get a reference to the ViewRefData. Requires tag == PLAN_VIEW_REF."""
        return self._view_ref.value()[]

    def cse_ref_data_ref(self) -> ref [origin_of(self._cse_ref.value()[])] CseRefData:
        """Get a reference to the CseRefData. Requires tag == PLAN_CSE_REF."""
        return self._cse_ref.value()[]

    def cast_to_varchar_data_ref(self) -> ref [origin_of(self._cast_to_varchar.value()[])] CastToVarcharData:
        """Get a reference to the CastToVarcharData. Requires tag == PLAN_CAST_TO_VARCHAR."""
        return self._cast_to_varchar.value()[]

    # =========================================================================
    # `BoxablePlan` conformance — what lets `Expr` carry a plan without naming
    # one
    # =========================================================================
    #
    # ⭐ TWO METHODS AND A TRAIT NAME IN THE STRUCT HEADER ARE THE ENTIRE COST
    # ON THIS SIDE. `Expr.correlated_subquery` is parametric over
    # `P: BoxablePlan` and infers `P` from its argument, so it can box a
    # `LogicalPlan` in a file that never names the type, with the ordinary
    # `Expr.correlated_subquery(...)` spelling at every call site.
    #
    # ⚠ `plan_tag` DUPLICATES `self.tag` ON PURPOSE, and the duplication is
    # what makes it reachable through a comptime bound: a trait can require a
    # METHOD, not a FIELD. Both compile to the same load.
    #
    # ⛔ DO NOT give a second type this conformance without minting it a NEW
    # `erased_type_tag`. The tag is the ONLY check standing between an
    # `ErasedBox` unbox and a type confusion — the bytes carry no type.

    @always_inline
    def plan_tag(self) -> UInt8:
        """This node's discriminant, reachable through `BoxablePlan`.

        Snapshotted into `CorrelatedSubqueryData.inner_tag` when a plan is
        boxed, so `Expr.write_to` can print `inner_tag=` without reaching the
        plan (the edge `Expr` must not have)."""
        return self.tag

    @always_inline
    def erased_type_tag(self) -> UInt32:
        """`LogicalPlan`'s `ErasedBox` identity. Compared on every unbox by
        `corr_subquery.corr_data_inner_plan_ref`, which RAISES on a mismatch."""
        return CORR_SUBQ_PLAN_TYPE_TAG

    # =========================================================================
    # Deep clone
    # =========================================================================

    def copy(self) -> Self:
        """Deep-clone the LogicalPlan tree.

        Tag-dispatches to the populated variant's `*Data.copy()`, which in turn
        recurses into any owned child plans via `child[].copy()`. Stays
        Movable-only — Mojo cannot auto-synthesize __copyinit__ on
        OwnedPointer-fielded structs.

        For SOURCE_IN_MEMORY scans, the InMemorySource arm of
        the SourceVariant holds an `ArcPointer[Slab[RecordBatch]]` and
        `.copy()` refcount-bumps the Arc (no buffer-byte copy) — a
        wall-time-cheap clone.
        """
        var plan = Self(self.tag, self.output_schema.copy())
        if self.tag == PLAN_SCAN and self._scan:
            plan._scan = Optional(OwnedPointer(self._scan.value()[].copy()))
        elif self.tag == PLAN_FILTER and self._filter:
            plan._filter = Optional(OwnedPointer(self._filter.value()[].copy()))
        elif self.tag == PLAN_PROJECT and self._project:
            plan._project = Optional(OwnedPointer(self._project.value()[].copy()))
        elif self.tag == PLAN_AGGREGATE and self._aggregate:
            plan._aggregate = Optional(OwnedPointer(self._aggregate.value()[].copy()))
        elif self.tag == PLAN_JOIN and self._join:
            plan._join = Optional(OwnedPointer(self._join.value()[].copy()))
        elif self.tag == PLAN_SORT and self._sort:
            plan._sort = Optional(OwnedPointer(self._sort.value()[].copy()))
        elif self.tag == PLAN_LIMIT and self._limit:
            plan._limit = Optional(OwnedPointer(self._limit.value()[].copy()))
        elif self.tag == PLAN_DISTINCT and self._distinct:
            plan._distinct = Optional(OwnedPointer(self._distinct.value()[].copy()))
        elif self.tag == PLAN_TOPN and self._topn:
            plan._topn = Optional(OwnedPointer(self._topn.value()[].copy()))
        elif self.tag == PLAN_PARTITION_BY and self._partition_by:
            plan._partition_by = Optional(OwnedPointer(self._partition_by.value()[].copy()))
        elif self.tag == PLAN_PARTITION_TOPN and self._partition_topn:
            plan._partition_topn = Optional(OwnedPointer(self._partition_topn.value()[].copy()))
        elif self.tag == PLAN_ASOF_JOIN and self._asof_join:
            plan._asof_join = Optional(OwnedPointer(self._asof_join.value()[].copy()))
        elif self.tag == PLAN_UNION and self._union:
            plan._union = Optional(OwnedPointer(self._union.value()[].copy()))
        elif self.tag == PLAN_VIEW_REF and self._view_ref:
            plan._view_ref = Optional(OwnedPointer(self._view_ref.value()[].copy()))
        elif self.tag == PLAN_CSE_REF and self._cse_ref:
            plan._cse_ref = Optional(OwnedPointer(self._cse_ref.value()[].copy()))
        elif self.tag == PLAN_CAST_TO_VARCHAR and self._cast_to_varchar:
            plan._cast_to_varchar = Optional(OwnedPointer(self._cast_to_varchar.value()[].copy()))
        return plan^

    # =========================================================================
    # Writable — human-readable plan tree representation
    # =========================================================================

    def write_to[W: Writer](self, mut writer: W):
        """Human-readable representation of the plan node."""
        from komira_plan_ir.plan_display import _write_plan_node
        _write_plan_node(writer, self, 0)

    # =========================================================================
    # Structural hash (the plan-compile cache key)
    # =========================================================================

    def structural_hash(self) -> UInt64:
        """FNV-1a hash of the plan's textual representation.

        Used by `OptimizerContext._cache_keys` to dedupe identical inner
        sub-plans across rule passes, and by `EngineContext` as the
        `factory_hash` half of the plan-compile cache key
        (`PlanCompileCache`, keyed on
        `hash_combine(factory_hash, stats_hash)`). Two plans with the same
        `write_to` output produce the same hash.

        ⚠⚠ THE RENDER IS THE HASH. THERE IS NO SECOND SOURCE OF IDENTITY.
        "The textual form captures every load-bearing structural axis" is a
        CLAIM ABOUT `plan_display._write_plan_node`, not a property of this
        function, and each way it can be false is a silent WRONG ANSWER, not a
        perf miss:

          * a source type with no `_source_type_name` arm renders
            `type=UNKNOWN`, merging it into every other unnamed type.
          * a binding-backed scan rendered by `binding.name` alone lets two
            distinct out-of-core scans sharing a name collide in the
            plan-compile cache (falsifier:
            `test_same_name_different_params_do_not_share_a_plan_cache_key`).
          * a source arm with no `ScanData.__init__` derivation renders
            `Scan(path="", type=PARQUET, source_kind=COLUMNAR)` — the same line
            for every path, hence ONE plan-compile cache key for every such
            scan (falsifiers `test_scan_binding_csv_arm.mojo
            :test_csv_scan_is_not_labelled_parquet` and
            `:test_two_paths_do_not_share_a_plan_cache_key`).
          * a `PartitionBy` (window) rendered without its order keys'
            direction, or with its functions as a bare `<N> funcs`, lets two
            windows in one `EngineContext` differing only in `descending`,
            the function kind, its column, offset, default, frame or alias
            share a compiled plan — the second query answers the FIRST one's
            values (falsifier `komira_sdk/tests/
            test_window_plan_cache_identity.mojo`). A lint that asks whether a
            field NAME is mentioned anywhere in `plan_display` is blind to
            this, because `descending` is (by the TopN arm).

        SO: a field added to any `*Data` payload does not enter plan identity
        until `_write_plan_node` EMITS it, and nothing goes red when it does
        not. A repository render-coverage lint fails on a `*Data` field that
        `plan_display` never mentions and on a `SOURCE_*` constant with no
        `_source_type_name` arm. A MENTION is not an EMISSION for the node that
        owns the field (above).

        The cost is one full plan-tree walk — fine for the optimizer
        rule's per-broadcast call site. Multi-broadcast or hot-path cache
        consultation could replace it with an inline structural traversal
        that incrementally folds tag + child hashes without the String
        allocation.

        PLAN_CSE_REF special-case: a `PLAN_CSE_REF` node's hash
        IS the `canonical_hash` it points at — NOT the FNV-1a of its own
        `write_to` text. Rationale: a CSE'd plan and a manually-written
        plan that references the same canonical subtree must hash
        identically (re-CSE idempotence; factory-cache stability).
        """
        if self.tag == PLAN_CSE_REF and self._cse_ref:
            return self._cse_ref.value()[].canonical_hash
        var s = String("")
        s.write(self)
        return _fnv1a_64_of_text(s)

    def structural_hash_modulo_inmem_id(self) -> UInt64:
        """`structural_hash` with every scan's KIND-SUPPLIED content identity
        replaced by a FIXED token — `inmem_id=` on the legacy in-memory arm and
        `bsid=` on a binding-backed one. The SAME render, minus the fields a
        kind computes for itself; core's DERIVED `bid=<identity_hash()>` is
        never placeholdered, which is what keeps the substitution FREE (measured
        0 merges over the registered kinds' identity corpora — audit rule R10).

        On the legacy in-memory arm that field's computation is O(RESIDENT
        BYTES) (`SourceVariant.structural_id` -> `InMemorySource.structural_id`
        -> `Column.content_hash`). On a binding-backed arm it is a stored
        `UInt64` and costs nothing to render — the placeholder is there for the
        key's CONTENT-BLINDNESS, not for its price.

        THIS IS A COARSENING, AND THAT IS THE WHOLE CONTRACT:

            structural_hash(a) == structural_hash(b)
              ==> structural_hash_modulo_inmem_id(a)
                    == structural_hash_modulo_inmem_id(b)

        (the converse does NOT hold — two subtrees over DIFFERENT in-memory
        content share this key.) It holds because both values are FNV-1a over
        the SAME traversal (`_write_plan_node`, one runtime flag apart), so the
        placeholdered render substitutes a constant for a variable at a fixed
        set of emission positions, which can only merge equivalence classes.
        See `_write_plan_node`'s docstring for why the flag must stay ON that
        walk rather than becoming a second one.

        USE: group candidate subtrees by this key FIRST, then compute the exact
        `structural_hash()` only inside groups of size >= 2. By the implication
        above no true duplicate is missed, and a false collision on this key
        costs only the exact hash that resolves it. `optimizer_agg_cse` is the
        one consumer; `structural_hash`'s ~10 consumers are untouched, and this
        method is NOT a substitute for it — a cheap key is not an identity.

        The PLAN_CSE_REF special case is mirrored from `structural_hash` so the
        two stay parallel by construction. (It is unreachable from the agg-CSE
        consumer, whose candidates are all PLAN_AGGREGATE, but a divergence here
        would be a coarsening violation in any future consumer.)"""
        if self.tag == PLAN_CSE_REF and self._cse_ref:
            return self._cse_ref.value()[].canonical_hash
        from komira_plan_ir.plan_display import _write_plan_node
        var s = String("")
        _write_plan_node(s, self, 0, placeholder_inmem_id=True)
        return _fnv1a_64_of_text(s)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    #
    # ⚠ THIS IS THE HUB OF THE CYCLE. The members of this cycle in
    # logical_plan_variants.mojo carry a destructor too; without one on
    # `LogicalPlan` itself the cycle stays open. It does NOT surface as
    # "field has non-'Deinitable' type" on this struct -- it surfaces two
    # files away as `Slab` refusing `OwnedPointer[LogicalPlan]`.
    def __deinit__(deinit self):
        pass


# =============================================================================
# Helper: FNV-1a 64 over plan text
# =============================================================================

def _fnv1a_64_of_text(s: String) -> UInt64:
    """FNV-1a 64-bit over `s`'s bytes. Walks via `as_bytes()` (no UnsafePointer
    in the public surface).

    Factored out so `structural_hash` and `structural_hash_modulo_inmem_id`
    provably share ONE fold: the coarsening contract between them is an
    argument about the two RENDERS, and it is only valid if the hash applied to
    those renders is literally the same function. Two copies of the FNV
    constants would let that assumption rot silently."""
    var h: UInt64 = 14695981039346656037  # FNV offset basis
    var prime: UInt64 = 1099511628211  # FNV prime
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = h ^ UInt64(b[i])
        h = h * prime
    return h


# =============================================================================
# Helper: infer Field from an Expr given a parent schema
# =============================================================================

def _infer_expr_field(expr: Expr, schema: Schema) -> Field:
    """Infer the output Field for `expr` given an input schema, returning a
    NULL PLACEHOLDER (never raising) for a column that is not in `schema`.

    ★ A ONE-LINE ADAPTER OVER `expr_walk.walk_expr_field` — THE ONE
    output-field inference — selecting the PLAN-BUILD-TIME column-reference
    policy. `compiler_helpers.field_for_expr` is the other adapter. Two
    separate copies of this inference drift — an arm present in one and
    missing in the other makes a projection export as Arrow type `null`.

    ⭐ THE PLACEHOLDER IS THE POINT, and it is the ONE arm the two entry
    points still differ on. This runs while a plan is being assembled and
    re-assembled by the optimizer; the plan VALIDATOR owns the "no such
    column" diagnostic because it can name the node and the columns that ARE
    available, where this function could only name the string. Raising here
    would be a regression. `field_for_expr`, which runs inside an operator
    over a real batch, pairs `ExecColRefFields` with a raising adapter
    instead.

    ⚠ CONTRACT-BOUND: the BinaryOp / Cast output-type rules are mirrored at
    comptime in the typed-schema surface (`infer_binary_out_type` + the
    `Column.cast[to]()` tag); the drift guard is
    `test_typed_sout_matches_runtime.mojo`. The comptime mirror covers
    the ARITHMETIC BinaryOp path only (it backs `Column.__add__` and
    friends), so the comparison/boolean BOOL carve-out has no typed-surface
    caller and the mirror stays arithmetic-faithful.

    ⛔ DO NOT RE-INLINE THE LADDER HERE. A second copy of this walk in this
    file is exactly the defect `expr_walk.mojo`'s header describes.

    ⛔ **THIS FUNCTION CANNOT RAISE, AND THAT IS MEASURED, NOT ASSUMED.**
    With `walk_expr_field` declared `raises`, the core packages does not build:

        komira_plan_ir/logical_plan.mojo: error: cannot call
        function that may raise in a context that cannot raise
        note: or mark surrounding function as 'raises'

    ⚠ A BARE `def` IS NOT IMPLICITLY RAISING ON THIS TOOLCHAIN (measured:
    `def f() -> Int: return r()` for a `raises` `r` is a compile error), and
    Mojo cannot make raises-ness depend on a comptime parameter — so a trait
    method declared `raises` "so both policies share one signature" makes
    EVERY instantiation raising, including the one whose body never raises.

    ⭐ **MARKING THIS FUNCTION `raises` IS THE WRONG FIX AND WAS REJECTED.**
    Its non-raising callers are `project` (`:1120`), `filter_with_udf`
    (`:1092`) and `schema_propagation.schema_column_type` (`:137`), so the
    effect would ripple through plan CONSTRUCTION, and the "never raising"
    contract in this docstring's first line is the property the placeholder
    policy exists to provide.

    ⛔ **A `try`/`except` AROUND THE CALL WAS ALSO REJECTED, AND IT IS WORTH
    SAYING WHY — IT COMPILES AND IT LOOKS HARMLESS.** An `except` arm
    returning `Field("expr", ArrowType.NULL, True)` reintroduces the exact
    failure this whole change deletes, in two ways:

      * IT SWALLOWS A REAL ERROR INTO AN UNEXPORTABLE COLUMN. The walk's only
        other raising callee was the decimal-mul result rule, which raises on
        an unrepresentable scale (s1+s2 > 38). Caught and turned into `null`,
        that becomes a column whose data is fine and whose declared type the
        Arrow C-ABI export refuses — `UnsupportedArrowCABIType: Arrow type
        'null' (export)`, arriving by a new route.
      * IT LOSES THE COLUMN NAME. The placeholder for a missing column is
        `Field(name, NULL, True)`, and the plan validator REPORTS that name;
        `Field("expr", NULL, True)` reports nothing.

    THE FIX IS THAT THERE IS NOTHING TO CATCH: `walk_expr_field` is
    NON-RAISING. It reports a missing column through a `mut missing: String`
    out-parameter, and the decimal rule is reached through
    `decimal_mul_result_ps_checked`, the non-raising core of
    `decimal_mul_result_ps`. `field_for_expr` — whose callers DO want a raise
    — converts a non-empty `missing` into `Schema.column_index`'s message
    verbatim. One ladder, two entry points, no swallowed errors.

    Args:
        expr: The expression to infer an output Field for.
        schema: The input schema the expression is evaluated against.
    """
    # ⛔ `missing` IS DISCARDED ON PURPOSE, AND THIS FUNCTION MUST STAY
    # NON-RAISING — see the docstring for the three non-raising callers that
    # make it so. The plan VALIDATOR owns the "no such column" diagnostic.
    var missing = String("")
    return walk_expr_field[PlanColRefFields](expr, schema, missing)


# =============================================================================
# Helper: infer Field from an AggExpr given a parent schema
# =============================================================================

def _disambiguate_field(mut seen: List[String], var field: Field) -> Field:
    """Make `field.name` unique against the names already accumulated in `seen`,
    appending `_1`, `_2`, ... on collision (the first occurrence keeps its bare
    name). Records the final (unique) name back into `seen`.

    `agg(sum(a), sum(b))` without aliases yields two output fields
    both named "sum" (`_infer_agg_field` keys the base name off the agg FUNC,
    not the input column). A duplicate output column name is silently dropped on
    the parquet round-trip (the reader resolves columns by name), so a 3-column
    aggregate (`[g, sum, sum]`) materialized back to 2 columns. DuckDB / Polars
    auto-disambiguate; this helper restores that for BOTH the column engine and
    the row-streaming engine (which mirrors this exact `_N` scheme in
    `row_streaming_segment._disambiguate_output_names`). A user-supplied
    `.alias(...)` already produces a distinct name and is left untouched unless
    it itself collides.
    """
    var base = field.name.copy()
    var candidate = base.copy()
    var n = 1
    while _name_in_list(seen, candidate):
        candidate = base + "_" + String(n)
        n += 1
    field.name = candidate.copy()
    seen.append(candidate^)
    return field^


def _name_in_list(names: List[String], name: String) -> Bool:
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def agg_func_base_name(func: UInt8) -> StaticString:
    """★ THE ONE PLACE AN UNALIASED AGGREGATE'S OUTPUT NAME IS SPELLED.

    `_infer_agg_field` (below) is the RUNTIME AUTHORITY on an aggregate's output
    Field, and this is the NAME half of that authority, lifted out so a PRODUCER
    can ask for the same string *before* it has an `AggExpr` to infer from. The
    SQL binder is exactly that caller: it forces an explicit alias onto every
    aggregate it binds (so its post-aggregate reorder Project can reference the
    column deterministically), which means an unaliased `count(*)` never reaches
    the `agg.alias_name`-is-empty branch below. A binder that filled that
    forced alias with a POSITIONAL synthetic — `_agg_<select-index>` — would
    produce a CROSS-SURFACE ANSWER DIFFERENCE, as measured on a ClickBench
    `count(*)`:

        sql=['_agg_0']  pandas=['count_star']  polars=['count_star']  mojo=['count']

    One row, one type, the same value in all four — and three different
    column names, because three producers each invented their own. A caller
    reads a result BY NAME, so that is an answer difference, not a cosmetic one.
    The answer is not a fourth convention: it is every producer asking THIS
    function, whose answer (`count`) is what the plan's own declared output
    schema already said.

    ⚠ RETURNS `StaticString`, DELIBERATELY. A `-> String` ladder over 3+ literals
    is the (pointer, length) constant-table pair that a shared-library link can
    bind crossed; a repository lint is the ratchet and `StaticString` is its
    measured-safe shape.

    ⚠ THIS IS THE PLAN'S FALLBACK WORD, NOT EVERY SURFACE'S ANSWER. A surface
    that has an ecosystem convention AUTHORS its own name into `AggExpr
    .alias_name` before `LogicalPlan.aggregate` runs, and this ladder is then
    never consulted for that aggregate — see `komira_sdk/agg_output_naming.mojo`
    (the Mojo dataframe surface, polars' rule) and `sql_binder._duckdb_agg_text`
    (the SQL surface, DuckDB's deparse). What still lands here is a surface
    that has no convention to be faithful to, and any child-less aggregate
    that is not `count(*)`.

    ⚠ THERE IS NO COMPTIME MIRROR OF THIS LADDER, DELIBERATELY. The typed
    grouped-agg `S_out` brand asks `agg_output_naming.polars_agg_out_name` —
    the same rule the typed builders' own plan carries — rather than a second
    word for one thing.

    Collisions between two unaliased aggregates of the same func are resolved by
    the `_N` scheme in `_disambiguate_field`; a producer that assigns names
    itself must apply the same scheme (the SQL binder's
    `_unaliased_agg_out_name` does).
    """
    if func == AGG_SUM:
        return "sum"
    if func == AGG_COUNT:
        return "count"
    if func == AGG_MIN:
        return "min"
    if func == AGG_MAX:
        return "max"
    if func == AGG_MEAN:
        return "mean"
    if func == AGG_COUNT_DISTINCT:
        return "count_distinct"
    if func == AGG_FIRST:
        return "first"
    if func == AGG_LAST:
        return "last"
    if func == AGG_STDDEV_SAMP:
        return "stddev_samp"
    if func == AGG_VAR_SAMP:
        return "var_samp"
    # ⭐ the POPULATION-FINALIZE family. Each
    # returns its SQL spelling, so an unaliased `SELECT g, var_pop(x) ...`
    # names its output column `var_pop`.
    if func == AGG_VAR_POP:
        return "var_pop"
    if func == AGG_STDDEV_POP:
        return "stddev_pop"
    if func == AGG_SEM:
        return "sem"
    # ⭐ the MONOID-FOLD family. `countif` and
    # `countif`'s sibling `count_if` are ONE tag, so the base name is the
    # canonical DuckDB spelling; the SOURCE TOKEN a customer actually wrote is
    # carried on the SX_CALL node and is what `_duckdb_expr_text` deparses, so
    # `SELECT countif(b)` is still named `countif(b)`.
    if func == AGG_COUNT_IF:
        return "count_if"
    if func == AGG_BOOL_AND:
        return "bool_and"
    if func == AGG_BOOL_OR:
        return "bool_or"
    if func == AGG_PRODUCT:
        return "product"
    if func == AGG_CORR:
        return "corr"
    if func == AGG_MEDIAN:
        return "median"
    if func == AGG_LARGEST_K:
        return "largest_k"
    # ⭐ the eleven BIVARIATE names. Each returns
    # its SQL spelling, so an unaliased `SELECT g, regr_slope(y, x) ...` names
    # its output column `regr_slope` and the executor-side
    # `agg_out_field_name` lands on the identical string the plan's declared
    # `output_schema` carries.
    if func == AGG_COVAR_POP:
        return "covar_pop"
    if func == AGG_COVAR_SAMP:
        return "covar_samp"
    if func == AGG_REGR_AVGX:
        return "regr_avgx"
    if func == AGG_REGR_AVGY:
        return "regr_avgy"
    if func == AGG_REGR_COUNT:
        return "regr_count"
    if func == AGG_REGR_SXX:
        return "regr_sxx"
    if func == AGG_REGR_SXY:
        return "regr_sxy"
    if func == AGG_REGR_SYY:
        return "regr_syy"
    if func == AGG_REGR_SLOPE:
        return "regr_slope"
    if func == AGG_REGR_INTERCEPT:
        return "regr_intercept"
    if func == AGG_REGR_R2:
        return "regr_r2"
    # ⭐ the ARRIVAL-ORDER PICK family's third
    # member. `AGG_FIRST` / `AGG_LAST` already return "first" / "last" above;
    # `any_value` is a DIFFERENT statistic (first NON-NULL, not first row) and
    # therefore a different tag with its own base name.
    if func == AGG_ANY_VALUE:
        return "any_value"
    # ⭐ The base name is the DEFAULT OUTPUT
    # COLUMN NAME, so a tag missing here emits a column called `agg` — three
    # `fsum`s in one SELECT list would collide on it rather than on their own
    # spellings. `fsum` / `sumkahan` share `AGG_KAHAN_SUM` with `kahan_sum`,
    # so ONE base name serves all three (DuckDB records both as `alias_of`
    # `kahan_sum`).
    if func == AGG_KAHAN_SUM:
        return "kahan_sum"
    if func == AGG_KAHAN_AVG:
        return "favg"
    if func == AGG_SKEWNESS:
        return "skewness"
    if func == AGG_KURTOSIS:
        return "kurtosis"
    if func == AGG_KURTOSIS_POP:
        return "kurtosis_pop"
    return "agg"


def agg_out_field_name(
    imm alias_name: Optional[String], func: UInt8, mut taken: List[String]
) -> String:
    """★ THE EXECUTOR'S HALF of `agg_func_base_name` — the name an aggregate's
    output column ACTUALLY gets, disambiguated exactly as the plan's declared
    `output_schema` disambiguated it.

    `agg_func_base_name` above is the BASE name; `_disambiguate_field` below is
    the `_N` collision scheme `LogicalPlan.aggregate` applies while BUILDING
    `output_schema`. This composes the two, so a PRODUCER that materialises the
    result batch itself — and therefore never reads `output_schema` — lands on
    the identical string. `taken` must already hold every name spoken for
    earlier in the SAME output schema (the group-key columns, then the
    aggregates assigned so far), because that is the order `aggregate` fills
    `seen_names` in; the chosen name is APPENDED to it.

    ⛔ WHY THIS EXISTS — OTHERWISE THE OUTPUT SCHEMA IS A FUNCTION OF THE DATA.
    MEASURED on two ClickBench queries whose plans are byte-identical apart
    from the predicate LITERAL, which disagreed about the name of their one
    output column:

        cb02  count(*) WHERE good_event = 1   -> every row group proven
              all-match by stats -> answered from the parquet footer by
              `metadata_fast_path._make_count_result`, which names its fields
              from `plan.output_schema`                        -> "count"
        cb03  count(*) WHERE event_date > 15901 -> a row group STRADDLES the
              predicate (39,787,655 of 99,997,497 rows eliminated) -> decoded
              through the ordinary agg executor, which named an unaliased
              aggregate `agg_<i>`                              -> "agg_0"

    So whether stats could decide the predicate — a property of the DATA —
    decided the output SCHEMA. Any caller reading a result by name, and any
    cache or contract keyed on output schema, passes on a small fixture and
    fails on real data. `test_agg_output_name_path_stable.mojo` is
    that pair as a test.

    The answer is not a fourth convention: it is every producer asking the SAME
    authority the plan already asked, rather than papering over a
    DECLARED-vs-PRODUCED gap with an invented `.alias(...)`.

    ⚠ AN ALIAS IS DISAMBIGUATED TOO, because `_disambiguate_field` disambiguates
    every field it is handed and does not special-case a user-supplied name."""
    var base: String
    if alias_name:
        base = String(alias_name.value())
    else:
        base = String(agg_func_base_name(func))
    var candidate = base.copy()
    var n = 1
    while _name_in_list(taken, candidate):
        candidate = base + "_" + String(n)
        n += 1
    taken.append(candidate.copy())
    return candidate^


def _infer_agg_field(agg: AggExpr, schema: Schema) -> Field:
    """Infer the output Field for an aggregation expression.

    Rules:
        COUNT(*) / COUNT(col) -> Field("count", INT64, non-null)
        SUM(col) -> Field("sum", promoted type — see below, nullable)
        MIN(col) -> Field("min", same type as col, nullable)
        MAX(col) -> Field("max", same type as col, nullable)
        MEAN(col) -> Field("mean", FLOAT64, nullable)
        COUNT_DISTINCT(col) -> Field("count_distinct", INT64, non-null)
        FIRST(col) / LAST(col) -> same type as col, nullable

    ⚠ CONTRACT-BOUND: this function is the RUNTIME AUTHORITY on aggregate
    output types (names, ArrowTypes, nullability). ⚠ THE NAME HALF NOW LIVES IN
    `agg_func_base_name` (just above) — same rule, hoisted so a PRODUCER can ask
    for it before it has an `AggExpr`, so no surface invents `_agg_<i>`. The
    comptime mirror `komira_sdk/typed_schema.mojo::agg_output_type`
    (output-TYPE rule) MUST stay byte-faithful with the logic below. There is
    no comptime mirror of the NAME rule: the typed grouped-agg brand reads
    `komira_sdk/agg_output_naming.polars_agg_out_name`, which is the rule its
    own plan carries. Edits here that change the type-inference semantics
    (e.g. extending the SUM promotion table, introducing a new agg kind,
    changing the COUNT result type) REQUIRE a matching edit to the comptime
    mirror AND to the drift-guard test
    (`test_typed_sout_matches_runtime.mojo` — the test asserts the
    runtime plan's Aggregate `output_schema` directly). The reciprocal pointer
    is in `typed_schema.mojo`'s `agg_output_type` header.
    """
    # Determine base name from agg function. ★ THE LADDER LIVES IN
    # `agg_func_base_name` (just above) so that a PRODUCER can ask for the same
    # string BEFORE it has an `AggExpr` to infer from — see its header.
    var base_name = String(agg_func_base_name(agg.func))

    # Use alias if provided
    var output_name: String
    if agg.alias_name:
        output_name = agg.alias_name.value()
    else:
        output_name = base_name

    # COUNT and COUNT_DISTINCT always return INT64.
    #
    # ⭐ `AGG_REGR_COUNT` JOINS THEM, AND NOT THE FLOAT64 BRANCH BELOW
    #. MEASURED DuckDB v1.5.3: `regr_count(y, x)`
    # over a group where every pair is NULL is **0**, and `regr_count(...) IS
    # NULL` is `false` there — counting an empty multiset is 0, the same
    # SQL:2016 asymmetry `count` carries and the reason both are declared
    # NON-nullable. Its ten bivariate siblings are all nullable FLOAT64.
    if (
        agg.func == AGG_COUNT
        or agg.func == AGG_COUNT_DISTINCT
        or agg.func == AGG_REGR_COUNT
    ):
        return Field(output_name, ArrowType.INT64, False)

    # MEAN always returns FLOAT64
    if agg.func == AGG_MEAN:
        return Field(output_name, ArrowType.FLOAT64, True)

    # STDDEV_SAMP / CORR / MEDIAN / LARGEST_K always return FLOAT64
    # regardless of input type. CORR additionally has TWO inputs (slot
    # 0 + slot 1) — both are promoted to Float64 internally by the
    # kernel; output is Pearson r. MEDIAN's input is Float64 (kernel
    # cast at update); output is the median value as Float64.
    # LARGEST_K (K=2): single Float64 input column; output is
    # the heap max (largest of top-K) as Float64.
    if (
        agg.func == AGG_STDDEV_SAMP
        or agg.func == AGG_VAR_SAMP
        or agg.func == AGG_CORR
        or agg.func == AGG_MEDIAN
        or agg.func == AGG_LARGEST_K
        # The ten FLOAT64 bivariates. All ten
        # finalize a ratio or a sum of squared/cross deviations off
        # `CorrelationState`, so the output is Float64 whatever the two inputs
        # were; `AGG_REGR_COUNT` is the eleventh and is handled with `count`
        # above because it is an INT64 that is never NULL.
        or agg.func == AGG_COVAR_POP
        or agg.func == AGG_COVAR_SAMP
        or agg.func == AGG_REGR_AVGX
        or agg.func == AGG_REGR_AVGY
        or agg.func == AGG_REGR_SXX
        or agg.func == AGG_REGR_SXY
        or agg.func == AGG_REGR_SYY
        or agg.func == AGG_REGR_SLOPE
        or agg.func == AGG_REGR_INTERCEPT
        or agg.func == AGG_REGR_R2
        # The three POPULATION finalizes. They
        # divide the same Welford `m2` the sample pair above divides, so the
        # output is Float64 whatever the input column's type was.
        or agg.func == AGG_VAR_POP
        or agg.func == AGG_STDDEV_POP
        or agg.func == AGG_SEM
        # `product` is ALWAYS FLOAT64, and that
        # is DuckDB v1.5.3's own rule rather than a widening chosen here:
        # `typeof(product(i))` over a BIGINT column is DOUBLE.
        or agg.func == AGG_PRODUCT
        # ⭐ the COMPENSATED sums and the
        # HIGHER-MOMENT trio, all ALWAYS FLOAT64. MEASURED v1.5.3:
        # `typeof(fsum(i))` over a BIGINT column is DOUBLE, and the only
        # declared signature of each of the five is `(DOUBLE) -> DOUBLE`.
        # ⛔ `fsum` MUST be named here and NOT left to the SUM-promotion
        # branch below: that branch returns the input's own width, which over
        # a BIGINT column gives `fsum` an INT64 cell and truncates exactly the
        # fractional part the compensation exists to keep.
        or agg.func == AGG_KAHAN_SUM
        or agg.func == AGG_KAHAN_AVG
        or agg.func == AGG_SKEWNESS
        or agg.func == AGG_KURTOSIS
        or agg.func == AGG_KURTOSIS_POP
    ):
        return Field(output_name, ArrowType.FLOAT64, True)

    # ⭐ the two BOOLEAN-valued aggregates. They
    # are the FIRST aggregates in this engine whose output cell is neither
    # INT64 nor FLOAT64, which is why `agg_is_bool_valued` is a predicate: the
    # extended fold, the wire codec and this function each had a two-way choice
    # that a scattered `or` would have left stale at one of them.
    # ⛔ NULLABLE, and not as a formality: MEASURED v1.5.3, an all-NULL group
    # answers NULL rather than the monoid identity.
    if agg_is_bool_valued(agg.func):
        return Field(output_name, ArrowType.BOOL, True)

    # ⭐ `count_if` is INT64 and, unlike `count`, NULLABLE.
    # MEASURED v1.5.3 over a group of one all-NULL row: `count_star()` = 1,
    # `count(b)` = 0, `count_if(b)` = NULL. Declaring it non-nullable beside
    # `AGG_COUNT` above would make the NULL unrepresentable.
    if agg.func == AGG_COUNT_IF:
        return Field(output_name, ArrowType.INT64, True)

    # For SUM: promote small integer/float types to avoid overflow.
    # INT8/INT16/INT32 -> INT64, UINT8/UINT16/UINT32 -> UINT64,
    # FLOAT32 -> FLOAT64. This matches standard SQL semantics and
    # prevents silent overflow on large datasets.
    if agg.func == AGG_SUM and agg.child:
        var child_field = _infer_expr_field(agg.child.value(), schema)
        var ct = child_field.arrow_type
        # PERF-CRITICAL: SUM type promotion — without this, SUM(INT32) returns
        # INT32 which overflows on datasets > 2B total. Also needed so that
        # the agg engine's Int64 accumulators match the declared output type.
        if ct == ArrowType.INT8 or ct == ArrowType.INT16 or ct == ArrowType.INT32:
            return Field(output_name, ArrowType.INT64, True)
        elif ct == ArrowType.UINT8 or ct == ArrowType.UINT16 or ct == ArrowType.UINT32:
            return Field(output_name, ArrowType.UINT64, True)
        elif ct == ArrowType.FLOAT32:
            return Field(output_name, ArrowType.FLOAT64, True)
        # ⭐  —
        # the two arms below state the type the 0-key fold ANSWERS
        # (`agg_scalar_fold.fold_scalar_agg_over_batch`), so a door that types
        # a result from this plan's `output_schema` and a door that types it
        # from the batch cannot disagree. Falling through to the bare 3-arg
        # ctor for both would declare a type NO route produces:
        #
        #   * `sum(<BOOL>)` would be declared BOOL — the fold answers the count of
        #     non-NULL TRUEs as INT64. INT64 is this engine's standing
        #     integer-SUM policy (DuckDB's HUGEINT, pyarrow's uint64 and
        #     polars' u32 are the libraries' own widths; the VALUE is the same,
        #     and a count of TRUEs cannot leave INT64 before the row count
        #     does).
        #   * `sum(<DECIMAL(p, s)>)` would be declared DECIMAL128 with (p, s)
        #     DROPPED — `DECIMAL(0, 0)`, which `Field.decimal128` itself
        #     refuses and which renders 212.61 as 21261. The fold answers
        #     DECIMAL(38, s): precision widened to the 128-bit maximum, the
        #     input's SCALE kept. MEASURED over a DECIMAL(12,2) column: DuckDB
        #     v1.5.3 `typeof(sum(v))`, pyarrow 25 `pc.sum` and polars 1.44.2
        #     `pl.col('v').sum()` all answer DECIMAL(38,2) — three libraries,
        #     one type, so this is not a DuckDB-only choice.
        #     ⛔ NOT `_pick_out_field` (the child's own (p, s)). Taking that
        #     copy REFUSES every total past 10^p; no library does either, and
        #     each door answers like its library.
        #     ⚠ An unparameterised or out-of-range child (p outside [1, 38], s
        #     outside [0, p]) keeps the bare ctor, for `_pick_out_field`'s
        #     reason: an already-illegal child must not turn a plan BUILD into
        #     an error — and the fold DECLINES such a column
        #     (`Column.as_decimal128` refuses it), so no answer is ever typed
        #     by that declaration. The literal 38 is `Field.decimal128`'s own
        #     upper bound, the one `_pick_out_field` also replicates: this
        #     function is NON-RAISING, so the raising factory cannot be called.
        if ct == ArrowType.BOOL:
            return Field(output_name, ArrowType.INT64, True)
        if ct == ArrowType.DECIMAL128:
            var in_p = child_field.decimal_precision
            var in_s = child_field.decimal_scale
            var dec_out = Field(output_name, ArrowType.DECIMAL128, True)
            if in_p >= 1 and in_p <= 38 and in_s >= 0 and in_s <= in_p:
                dec_out.decimal_precision = 38
                dec_out.decimal_scale = in_s
            return dec_out^
        # INT64, UINT64, FLOAT64 stay as-is
        return Field(output_name, ct, True)

    # For MIN, MAX, FIRST, LAST, ANY_VALUE: infer type from the child expression
    # (NO promotion). ⭐ the arrival-order family
    # PICKS an existing value, so its output type IS the input's — MEASURED
    # v1.5.3, `typeof(first(i))` over a BIGINT column is BIGINT, `typeof(
    # any_value(x))` over a DOUBLE is DOUBLE and `typeof(arbitrary(b))` over a
    # BOOLEAN is BOOLEAN. It reaches this branch by falling past every rule
    # above rather than by being named; that is deliberate (a pick has no
    # output rule of its own) and is why this comment names the tags.
    if agg.child:
        var child_field = _infer_expr_field(agg.child.value(), schema)
        return _pick_out_field(output_name, child_field)

    # Fallback
    return Field(output_name, ArrowType.NULL, True)


def _pick_out_field(output_name: String, child_field: Field) -> Field:
    """The output Field for a PICKING aggregate — MIN / MAX / FIRST / LAST /
    ANY_VALUE — renamed to `output_name` and NULLABLE.

    ⛔⛔ THE WHOLE REASON THIS IS A FUNCTION AND NOT `Field(output_name,
    child_field.arrow_type, True)` IS THAT `ArrowType` IS A BARE
    DISCRIMINATOR AND THE TYPE'S PARAMETERS DO NOT LIVE IN IT. Two of the
    Arrow types this engine serves are parameterised, and BOTH carry their
    parameters on the `Field`:

      * `Timestamp(unit, tz)` — `timestamp_us_utc` IS NOT ITS OWN
        `ArrowType`. A UTC timestamp and a naive one are BOTH
        `ArrowType.TIMESTAMP_US`, discriminated ONLY by `Field._tz`.
      * `Decimal128(precision, scale)` — one `ArrowType.DECIMAL128` for every
        (p, s), which live in `Field.decimal_precision` / `.decimal_scale`.

    So reading `child_field.arrow_type` and rebuilding through the bare 3-arg
    ctor implements "infer the type from the child" as "infer the
    DISCRIMINATOR from the child" and DEFAULTS THE PARAMETERS AWAY — a naive
    timestamp and a `DECIMAL128(0, 0)`. ⇒ Take the `Field`, never the
    `ArrowType`. (The engine's mirror of this rule, fixed first, is
    `komira_engine_dispatch/agg_node_exec.mojo::_agg_out_field`; its group-key
    sibling `_agg_key_out_field` states the same hazard.)

    ⚠ `DECIMAL128(0, 0)` IS NOT MERELY UNDER-SPECIFIED, IT IS ILLEGAL.
    `Field.decimal128` REFUSES `precision < 1` ("precision must be in
    [1, 38]") and the C Data Interface format string is `d:0,0`, which
    arrow-cpp / pyarrow / arrow-rs all reject on import. This function
    therefore declines to build one: an unparameterised DECIMAL128 child
    falls through to the bare ctor unchanged rather than raising, because a
    pre-existing illegal input must not turn a plan BUILD into an error.

    ORACLE — DuckDB v1.5.3, MEASURED, not inferred. Over a
    `TIMESTAMPTZ`, all five of min/max/first/last/any_value answer `TIMESTAMP
    WITH TIME ZONE`; over a `DECIMAL(12,2)`, all five answer `DECIMAL(12,2)`.
    A pick returns an element of its input multiset, so its output type IS
    its input's — which is exactly the rule the branch above states and the
    bare ctor would break.

    ⛔ AND THE PARAMETER MUST COME FROM THE CHILD FIELD, NEVER BE MINTED FROM
    THE TYPE. Stamping "UTC" because `arrow_type.is_timestamp()` is the
    MIRROR-IMAGE wrong answer and the cross-surface corpus has cells for both
    a naive `timestamp_us` and a `timestamp_us_utc`; the over-fix guards in
    `test_infer_agg_field_keeps_timestamp_zone.mojo` §3 / §8 are real arms.

    ⭐ `sum` over a DECIMAL is NOT handled here. Declaring it through the bare
    ctor would show the same symptom (`DECIMAL128(0, 0)`), but its right
    answer is DIFFERENT: a PROMOTION, not this parameter copy
    (`agg_scalar_fold`'s 0-key DECIMAL SUM, an exact int256 total published
    as DECIMAL(38, s)), which the SUM branch declares. A SUM is not a pick,
    so it deliberately does NOT call this function."""
    var at = child_field.arrow_type
    var out = Field(output_name, at, True)
    # ⛔⛔ THE SLOTS ARE SET DIRECTLY AND *NOT* THROUGH `Field.timestamp` /
    # `Field.decimal128` / `Field.decimal256`, AND THAT IS FORCED, NOT A
    # PREFERENCE. All three factories RAISE (they validate their parameters),
    # and `_infer_agg_field` — the only caller — is NON-RAISING because
    # `LogicalPlan.aggregate` and `schema_propagation` call it from
    # non-raising contexts. Making it raise is a signature change across the
    # whole plan-build path for a validation this function must not perform
    # anyway: an already-illegal `(p, s)` arriving from the CHILD schema must
    # not turn plan BUILD into an error. So the guards below REPLICATE the
    # factories' bounds and the assignment is the same one they make
    # internally (`f._tz = timezone`; `f.decimal_precision = precision`).
    # ⇒ If a factory's bounds ever change, these guards must change with it.
    if at.is_timestamp():
        var tz = child_field.timezone()
        if tz.byte_length() > 0:
            out._tz = tz
        return out^
    if at == ArrowType.DECIMAL128 or at == ArrowType.DECIMAL256:
        var prec = child_field.decimal_precision
        var scale = child_field.decimal_scale
        # `Field.decimal128` enforces 1 <= p <= 38, `Field.decimal256`
        # 1 <= p <= 76, and both 0 <= s <= p. An out-of-range child is left
        # unparameterised rather than clamped — clamping would invent a type
        # the source never had.
        var max_prec = 38 if at == ArrowType.DECIMAL128 else 76
        if prec >= 1 and prec <= max_prec and scale >= 0 and scale <= prec:
            out.decimal_precision = prec
            out.decimal_scale = scale
        return out^
    return out^


# Display logic has been extracted to plan_display.mojo
# _write_plan_node, _source_type_name, _join_type_name are in plan_display.mojo
