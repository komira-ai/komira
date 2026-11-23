# =============================================================================
# parquet_source_data -- the Parquet morsel source's configuration
# =============================================================================
#
# `ParquetSourceData` and `ParquetRowWindow` of the PhysicalPlan IR, moved out
# of `physical_plan` unchanged so that file stays under 1000 lines.
# `physical_plan` imports both names, so
# `from physical_plan.physical_plan import ParquetSourceData` still resolves;
# `PHYSICAL_PLAN_IR_VERSION` and its bump policy cover these structs as before.
# Inert data, like the rest of the IR.
# =============================================================================

from plan_expr.expr import Expr
from plan_expr.partition_pred_pod import PartitionPredicatePod
from plan_expr.fs_descriptor_pod import FsDescriptorPod
from plan_expr.payload_narrow import PayloadNarrowSpec
from arrow.schema import Field


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
            its scheme the code source_url maps the source URL's
            prefix to. Defaulted to `FsDescriptorPod.local()` (scheme=FILE,
            node_id=-1) — the local default. Core names NO FS type here —
            only the identity POD; the file system that reads the source is
            the one whose `SCHEME` is this scheme. See
            `plan_expr/fs_descriptor_pod.mojo`.
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
    #     instructions the host derives while it lowers the plan
    #     (`lowering_rules.derive_payload_narrow`) and sets here (not in
    #     this tree). EMPTY at construction at every site (it is deliberately
    #     NOT a ctor argument).
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
