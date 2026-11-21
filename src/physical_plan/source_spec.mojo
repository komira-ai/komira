# =============================================================================
# source_spec -- the Parquet source configuration and the inline source spec
# =============================================================================
#
# Split out of `physical_plan.mojo` (rule M15, files under 1000 lines): the
# `SOURCE_*` tags, `ParquetRowWindow`, `ParquetSourceData` and `SourceSpecPod`.
# `physical_plan.mojo` imports every name here, so
# `from physical_plan.physical_plan import SourceSpecPod` still resolves. These
# structs are INERT data, like the rest of the IR (see `physical_plan.mojo`).
# =============================================================================

from plan_expr.expr import Expr
from plan_expr.partition_pred_pod import PartitionPredicatePod
from plan_expr.fs_descriptor_pod import FsDescriptorPod
from plan_expr.payload_narrow import PayloadNarrowSpec
from arrow.schema import Field



# Source tags (`SegmentDescPod.source_kind`)
comptime SOURCE_PARQUET: UInt8 = 0     # Read from Parquet file
comptime SOURCE_BATCH: UInt8 = 1       # Read from in-memory RecordBatch
comptime SOURCE_SINK_OUTPUT: UInt8 = 2 # Read from a completed sink's output
comptime SOURCE_CONCAT: UInt8 = 3      # Concatenate N completed sinks' outputs
                                       # (the physical form of PLAN_UNION)


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


struct SourceSpecPod(Movable):
    """POD source spec — the closed 4-kind `SOURCE_*` vocabulary as an
    INLINE descriptor field (source symmetry: the source set is bounded and
    is NOT the growth axis a new SINK kind widens, so it stays inline, not erased).

    Exactly one variant is meaningful, keyed by the enclosing descriptor's
    `source_kind`:
      * SOURCE_PARQUET: `parquet_path` + `parquet_projection` (pushed) +
        `parquet_filter` (pushed decode filter); a source of several files or
        with Hive partition columns also carries `parquet_paths`,
        `parquet_partition_cols` and `parquet_partition_values`.
      * SOURCE_SINK_OUTPUT: `dep_seg_ids[0]` = the producer segment whose output
        this reads.
      * SOURCE_CONCAT: `dep_seg_ids` = the N producer segments, concat order.
      * SOURCE_BATCH: `batch_handle_id` = index into the driver's batch table.

    Every field is inert: `String`, `Optional[List[String]]`, `Optional[Expr]`,
    `List[Int]`, `List[Field]`, `List[List[String]]`, `Int`, `Bool`. Passes the
    inert-IR lint.

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
    define. Since IR version 15 the pod carries the file list
    (`parquet_paths`) and the Hive partition constants, so a source of several
    files is total too; a scan on another file system, an unbounded one or a
    lazy Hive shape (a directory scan, a partition predicate) is still not
    carried and is refused at the cut."""
    var parquet_paths: List[String]
    """SOURCE_PARQUET ONLY. Every file of the source, in read order. Empty for
    a spec built by `parquet()`, which names one file in `parquet_path`; a spec
    built by `parquet_files()` holds at least one, and `parquet_path` is the
    first."""
    var parquet_partition_cols: List[Field]
    """SOURCE_PARQUET ONLY. The Hive partition columns, after the files' own
    columns. Empty when the files carry none."""
    var parquet_partition_values: List[List[String]]
    """SOURCE_PARQUET ONLY. `[file][column]`: the decoded value text of each
    partition column for each file of `parquet_paths`. Empty when
    `parquet_partition_cols` is."""
    var dep_seg_ids: List[Int]                   # SOURCE_SINK_OUTPUT (len 1) / SOURCE_CONCAT (len N)
    var batch_handle_id: Int                     # SOURCE_BATCH (-1 unused)

    def __init__(out self):
        """Empty spec (SOURCE_SINK_OUTPUT/CONCAT default: fill dep_seg_ids)."""
        self.parquet_path = String("")
        self.parquet_projection = None
        self.parquet_filter = None
        self.parquet_spec_is_total = False
        self.parquet_paths = List[String]()
        self.parquet_partition_cols = List[Field]()
        self.parquet_partition_values = List[List[String]]()
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
    def parquet_files(
        var paths: List[String],
        var partition_cols: List[Field],
        var partition_values: List[List[String]],
        var projection: Optional[List[String]],
        var pushed_filter: Optional[Expr],
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
