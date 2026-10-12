# =============================================================================
# komira_op_typed_source_api.typed_source -- the source axis of the typed IO
#   path: the `TypedSource` and `SourceReader` traits, the `FlatContribution`
#   value a source contributes to a flattened plan, and the leaf-aggregation
#   RADIX-vs-FLAT decision helpers.
# =============================================================================
#
# WHERE THE TRAITS LIVE: the trait signatures name `ParquetMetadataCache`
#   (komira_parquet) and the engine types `ParquetSourceData` / `MorselOp`
#   (komira_physical_plan), `MorselSizingPolicy` (komira_engine_runtime) and
#   `DynamicJoinFilter` (komira_morsel). This package is the lowest one that
#   sees all of them. Both the concrete parquet conformer
#   (`TypedParquetSource` / `ParquetReader`, package komira_op_typed_source)
#   and the dispatch and SDK consumers depend on it, and it depends on none of
#   them, so no edge closes a cycle. A consumer names these traits and
#   instantiates only the conformers it uses.
#
# NO HIGHER-KINDED TYPES: the natural shape would be
#   `trait SourceReader { comptime Source: TypedSource;
#   build_source[FS](...) -> Self.Source[FS] }`, with `Source` a type
#   constructor applied to FS per call. Mojo has no higher-kinded types, so the
#   READER is FS-parametric (`ParquetReader[FS]`) and its
#   `comptime Source = TypedParquetSource[FS]` is fully applied. The FS lives on
#   the reader; the composed source is the reader's associated type.
#
# SCOPE: `TypedSource` carries the non-breaker collect leaf
#   (`materialize_into_source`), `clone` and `descriptor`, plus the grouped-agg
#   leaves and the decline-returning hooks below. The other breaker leaves
#   (sort, top-n, join, partition-by, count-distinct) live in the dispatch tier,
#   which sits above this package.
#
# Pointers: no `UnsafePointer`, no wildcard origin, no `unsafe_from_address`.
#   The conformers hold their FS as a plain owned value.
# =============================================================================

from std.memory import ArcPointer

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_async_api.token import CancellationToken
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_ir.logical_plan_variants import AggregateData
from komira_physical_plan.physical_plan import ParquetSourceData, MorselOp
from komira_scan_source.source_variant import SourceVariant
from komira_fs.file_system import FileSystem
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_collections.slab import Slab
from komira_column_format.column_format_storage import ColDescriptor
from komira_op_agg_row_api.agg_spec import AggSpec
from komira_engine_runtime.morsel_sizing_policy import MorselSizingPolicy
from komira_morsel.dynamic_join_filter import DynamicJoinFilter
from komira_scan_source.scan_registry import ScanRegistry
from komira_parquet.runtime_footer_cache import ParquetMetadataCache

# The untyped leaf aggregation's RADIX-vs-FLAT routing threshold for a
# single-integer-key, unfiltered aggregation. When the key's footer-proven
# domain is at least this crossover, the leaf routes to the RADIX strategy
# (the fused hash-agg sink's 64-way partition-aligned parallel combine)
# instead of FLAT (whose cross-worker partial merge is close to serial). The
# dispatch tier's in-memory aggregation uses the same crossover; the two live
# in different packages, so the value is duplicated and must be kept in sync.
# The probe ceiling is large so that the domain is always computed.
comptime _UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER: Int = 5_000
comptime _UNTYPED_AGG_RADIX_PROBE_CEILING: Int = 1 << 50

# The RADIX route by total rows, for a COMPOSITE-key or FILTERED leaf.
#
# The single-integer-key domain gate above cannot fire for a composite key
# (there is no single-integer footer domain) nor for a filtered leaf. Such a
# leaf takes RADIX when the footer's total row count clears this threshold.
# Rows over-estimate groups (rows >= groups), and over-estimate them further
# under a selective filter, but RADIX returns the same values as FLAT for every
# aggregation the descriptor build admits (`_agg_parallel_byte_stable`), so an
# over-estimate costs only the 64-partition move-stash, never a wrong answer.
# FLAT is still reached by every below-threshold leaf and by every leaf whose
# group count is provably low (`_leaf_agg_group_estimate_declines`).
#
# The dispatch tier's in-memory RADIX engage uses the same rows threshold; the
# value is duplicated across packages and must be kept in sync.
comptime _LEAF_AGG_RADIX_MIN_ROWS_DEFAULT: Int = 500_000


def _leaf_agg_radix_min_rows() -> Int:
    """The footer total-rows threshold of the by-rows RADIX route:
    `_LEAF_AGG_RADIX_MIN_ROWS_DEFAULT`. A caller that needs another threshold
    passes `min_rows` to `_leaf_agg_radix_by_rows_decision`."""
    return _LEAF_AGG_RADIX_MIN_ROWS_DEFAULT


def _leaf_agg_radix_min_groups() -> Int:
    """The group-count floor of the by-rows RADIX route:
    `_UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER`, the same crossover the single-key
    domain gate uses, so that the two low-cardinality gates agree. A caller
    that needs another floor passes `min_groups`."""
    return _UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER


def _leaf_agg_group_estimate_declines(
    group_estimate: Int, min_groups: Int = _UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER
) -> Bool:
    """The group-cardinality decline guard. The 64-way move-stash costs in
    proportion to the ROW count; the parallel combine pays off in proportion to
    the GROUP count. A provably low group count
    (`0 <= group_estimate < min_groups`) pays the per-row stash for little
    combine benefit, so RADIX is declined and the leaf stays FLAT (for example
    a single key with 10 groups over 6M rows). A negative estimate (-1) means
    UNKNOWN: a composite, filtered or statistics-less leaf whose group count is
    not provable at the leaf. It does not decline. The default floor is the
    single-key domain crossover; a key range-domain is at least its distinct
    count, so `range-domain < floor` proves `distinct < floor` and the decline
    is never a false low."""
    return group_estimate >= 0 and group_estimate < min_groups


def _leaf_agg_radix_by_rows_decision(
    total_rows: Int,
    group_estimate: Int,
    min_rows: Int = _LEAF_AGG_RADIX_MIN_ROWS_DEFAULT,
    min_groups: Int = _UNTYPED_AGG_RADIX_DOMAIN_CROSSOVER,
) -> Bool:
    """The one by-rows RADIX decision, made before dispatch. True iff both:
      * `total_rows >= min_rows`, the large-scale rows proxy;
      * not `_leaf_agg_group_estimate_declines(group_estimate, min_groups)`,
        the low-cardinality decline guard.
    `group_estimate` is the best group-count proxy the caller has: the leaf
    collect passes the single-integer key's footer range-domain, else -1 for a
    composite or filtered leaf; the in-memory aggregation passes its probed
    domain, else the plan's estimated groups, else -1. -1 means unknown and
    admits. The caller has already confirmed that the aggregate descriptors are
    `_agg_parallel_byte_stable`."""
    return total_rows >= min_rows and not _leaf_agg_group_estimate_declines(
        group_estimate, min_groups
    )


# =============================================================================
# The plan-contribution value type.
# =============================================================================
struct FlatContribution(Movable, Deinitable):
    """The result of `TypedSource.contribute_flat_plan`.

    Two states:
    - **Flat** (`_plan` is `Some`): a real-leaf `LogicalPlan` subtree this
      source contributes, with real scans at the leaves and no synthetic
      breaker scans.
    - **Decline** (`_plan` is `None`, `_reason` set): this source's shape cannot
      be represented faithfully as a reorderable plan (a residual SEMI/ANTI
      join, a widening node that carries a UDF). The caller keeps the frame
      unflattened and runs the author-order path. A decline propagates: one
      declining frame declines the whole chain. Declining is always safe."""

    var _plan: Optional[LogicalPlan]
    var _reason: String

    def __init__(out self, var plan: Optional[LogicalPlan], var reason: String):
        self._plan = plan^
        self._reason = reason^

    @staticmethod
    def flat(var plan: LogicalPlan) -> FlatContribution:
        return FlatContribution(Optional[LogicalPlan](plan^), String(""))

    @staticmethod
    def decline(var reason: String) -> FlatContribution:
        return FlatContribution(None, reason^)

    def is_declined(self) -> Bool:
        return not self._plan.__bool__()

    def reason(self) -> String:
        return self._reason

    def plan_copy(self) -> LogicalPlan:
        """Copy the contributed flat plan (asserts Flat; the caller checks
        `is_declined()` first)."""
        return self._plan.value().copy()

    def take_plan(mut self) -> LogicalPlan:
        """Move the contributed flat plan out (asserts Flat)."""
        return self._plan.take()


# =============================================================================
# trait TypedSource -- a source with a compile-time FS.
# =============================================================================
trait TypedSource(Movable, Deinitable):
    """A SOURCE that carries one compile-time FS and the typed materialize
    surface.

    A `TypedSource` is the compile-time handle that rides READ -> MATERIALIZE
    alongside the source-erased plan. It carries one concrete FS (`comptime Fs`)
    and exposes the collect leaf (`materialize_into_source`), supplying the FS
    itself (the conformer holds the live FS). The SDK's
    `materialize(ScanFrame[S])` delegates to this leaf, so the SDK names no FS
    and no format leaf.

    A `TypedParquetSource[Fs]` names only one FS, never a registry of file
    systems or the union of cloud backends: a `materialize` over
    `TypedParquetSource[LocalFs]` names no cloud backend.

    Other sources (csv, jsonl and avro in this package) conform here without
    changing the SDK's generic code."""

    comptime Fs: FileSystem
    """The concrete FS this source reads through."""

    comptime supports_fused_join_probe: Bool = False
    """Whether this source is a real PARQUET scan leaf that can serve as the
    scan-fused join PROBE side. Only `TypedParquetSource[Fs]` sets it to True;
    every widening breaker and in-memory `TypedSource` keeps the False default.
    The join resolver instantiates the fused-probe driver under
    `@parameter if SL.supports_fused_join_probe`, so only a binary with a
    parquet probe elaborates that driver."""

    def clone(self) raises -> Self:
        """Return an independent source bound to the same live FS."""
        ...

    def descriptor(self) raises -> SourceVariant:
        """The source-identity descriptor (the `SourceVariant` arm the READ side
        builds the scan plan from). The materialize path reads the per-source
        identity off `ParquetSourceData` (node_id), not off this, so this is not
        on the materialize hot path."""
        ...

    def materialize_into_source(
        self,
        node_id: Int,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        pq_data: ParquetSourceData,
        operators: Slab[MorselOp],
        policy: MorselSizingPolicy,
        mut footer_cache: ParquetMetadataCache,
        count_only: Bool,
        var dyn_filter_arc: Optional[ArcPointer[DynamicJoinFilter]],
        var dyn_filter_key: String,
        var extra_pushed_filter: Optional[Expr],
        scan_registry: ScanRegistry = ScanRegistry(unbound=True),
    ) raises -> RecordBatch:
        """The collect leaf: execute a non-breaker `SCAN -> FILTER* ->
        PROJECT?` collect over this source's FS, supplying the live FS itself.
        Names only `Self.Fs`."""
        ...

    def resolve_agg_scan_schema(
        self,
        pq_data: ParquetSourceData,
        mut footer_cache: ParquetMetadataCache,
    ) raises -> Schema:
        """Read the scan schema from the footer (no row-group decode) through
        this source's FS, so that the caller can build the untyped agg
        descriptors before the fused feed (one pass, no collect-all). Names only
        `Self.Fs`."""
        ...

    def materialize_agg_into_source(
        self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        pq_data: ParquetSourceData,
        operators: Slab[MorselOp],
        var key_descriptors: List[ColDescriptor],
        var agg_descriptors: List[AggSpec],
        var output_schema: Schema,
        policy: MorselSizingPolicy,
        mut footer_cache: ParquetMetadataCache,
    ) raises -> RecordBatch:
        """The grouped-agg breaker leaf: stream this source through the fused
        hash-agg sink and return the resident result, supplying the live FS
        itself. Names only `Self.Fs`. The strategy changes only the shape of the
        parallel combine, never the values."""
        ...

    def try_materialize_extended_agg_sink_source(
        self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        imm agg_data: AggregateData,
        source_path: String,
        policy: MorselSizingPolicy,
        mut footer_cache: ParquetMetadataCache,
    ) raises -> Optional[RecordBatch]:
        """The streaming extended-agg leaf: the order-independent extended
        aggregates (LARGEST_K, CORR) stream this source straight into the
        parallel struct sink, supplying the live FS itself. Returns None to
        decline, and the caller then keeps the resident fold (MEDIAN, filtered
        or out-of-envelope shapes). The default body declines: only
        `TypedParquetSource[Fs]` overrides it, so every other conformer falls
        back to the fold with no per-conformer code."""
        _ = cancel_token^
        _ = source_path
        _ = policy
        return None

    def try_clone_fs(self) raises -> Optional[Self.Fs]:
        """Decline-returning FS accessor. A PARQUET source returns a clone of
        its live FS, so that a single-join resolver can route the scan-fused
        parquet probe (build the hash table from the small in-memory side, then
        decode and probe the large parquet side in one pass, never
        materializing it). The default body declines (None): a widening breaker
        or in-memory `TypedSource` has no standalone FS to hand out (its
        `Self.Fs` is a sentinel), so the caller keeps the decode-both-resident
        path. Only `TypedParquetSource[Fs]` overrides it."""
        return None

    def try_materialize_agg_over_join_into_source(
        self,
        mut dispatcher: LocalDispatcher[NoopSink],
        var cancel_token: CancellationToken,
        imm agg_data: AggregateData,
        policy: MorselSizingPolicy,
        mut footer_cache: ParquetMetadataCache,
        scan_registry: ScanRegistry = ScanRegistry(unbound=True),
    ) raises -> Optional[RecordBatch]:
        """Aggregate over a join in the probe pass: a grouped aggregate whose
        source is a fused breaker JOIN folds the join-output morsels straight
        into a hash-agg sink during the probe, never materializing the join
        output. Returns None to decline, and the caller then keeps the
        decode-then-resident-agg path. The default body declines: only the typed
        join frame (whose source is a two-source join) overrides it."""
        _ = cancel_token^
        _ = policy
        return None

    def contribute_flat_plan(self) raises -> FlatContribution:
        """Contribute this source's real-leaf flat `LogicalPlan` subtree (the
        synthetic-scan breaker composition, un-nested).

        The default body is the LEAF placeholder. A real parquet leaf's scan
        (with footer schema and row count) lives in the owning
        `ScanFrame._plan`, not in the bare source, and a leaf source is never
        the target of a synthetic-scan splice (only breaker frames widen to
        synthetic scans). So the default returns a Flat placeholder that is
        never spliced. It must be Flat, not Decline, so that a real-leaf join
        does not decline. The breaker frames override this to recurse and
        splice."""
        var sv = self.descriptor()
        return FlatContribution.flat(
            LogicalPlan.scan_from_source(sv^, Schema(), row_count=None)
        )


# =============================================================================
# trait SourceReader -- a compile-time format + FS handle.
# =============================================================================
trait SourceReader(Movable, Deinitable):
    """A compile-time FORMAT + FS handle that the `read_file` entry binds.

    A `SourceReader` carries the chosen FS (`comptime Fs`) and the composed
    `TypedSource` (`comptime Source`), and exposes two builders:
    `build_source` (the live typed source for one read) and `build_scan_plan`
    (the lazy scan `LogicalPlan` node). The SDK's generic
    `read_file[Reader, FS]` composes a `ScanFrame[Reader.Source]` from them, so
    the source and FS types thread READ -> MATERIALIZE through the typed
    `ScanFrame`, not through the source-erased DataFrame chain.

    The parquet conformer is `ParquetReader[FS]`; this package holds the csv,
    jsonl and avro conformers. A new format is a new conformer whose `Source` is
    its own `TypedSource`; the SDK's generic code does not change."""

    comptime Fs: FileSystem
    """The concrete FS this reader reads through."""

    comptime Source: TypedSource
    """The composed `TypedSource` this reader produces. The `ScanFrame` the
    read returns is generic over this type."""

    def build_source(var self) raises -> Self.Source:
        """Consume the reader's bound FS and return the live `TypedSource` that
        rides READ -> MATERIALIZE."""
        ...

    def build_scan_plan(self, path: String) raises -> LogicalPlan:
        """Build the LAZY scan `LogicalPlan` node for `path` (reads nothing
        beyond the optional footer or header; the leaf runs at materialize
        time)."""
        ...
