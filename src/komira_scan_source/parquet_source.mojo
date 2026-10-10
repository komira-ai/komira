# =============================================================================
# ParquetSource — concrete SourceLike for parquet files on disk.
# =============================================================================
#
# A ParquetSource carries:
#
#   - paths: one-or-more parquet file paths on disk (or s3:// / gs:// URIs
#     when those land). A single-element list is the degenerate single-file
#     case (`path` is kept as a derived alias = `paths[0]`).
#   - schema_cached: data schema (the COLUMNS that live in the parquet
#     files, NOT including any Hive partition columns). Read from the
#     parquet footer at construction (footer-read is metadata-only;
#     compatible with the prepared-statement model). The caller passes the
#     parsed Schema explicitly.
#   - partition_cols: the Hive partition columns parsed from the path
#     components (`/year=2024/month=05/`). Empty unless detected or
#     supplied explicitly. Each is a Field carrying (name, inferred type,
#     nullable=False).
#   - partition_values: per-path, per-partition-col STRING values (the raw
#     `<value>` text from the path; the engine projects these as constant
#     columns at scan time, parsing to the partition_cols[i] type). Outer
#     index = path index, inner index = partition col index. Empty when
#     `partition_cols` is empty. Mirrors DuckDB's hive_partitioning.
#   - name: optional EXPLAIN/debug label; NOT used for fingerprint.
#   - _mtime_ns: per-path file modification time (nanoseconds since unix
#     epoch) at construction. ALL paths' mtimes are folded into
#     fingerprint() so the plan-compile cache invalidates when ANY
#     underlying file is rewritten (stale-cache contract). For multi-file
#     the caller supplies a single representative mtime.
#
# Fingerprint shape: FNV-1a over the SORTED, length-prefixed
# concatenation of all paths, hash_combined with the partition-col names
# and the representative mtime. Two ParquetSources over the same path-set
# (regardless of construction order) + same mtime → same fingerprint
# (cache hit). Any path changed / added / removed, or any partition col
# renamed, or any path rewritten → different fingerprint (cache miss).
#
# `to_dataframe()` is NOT declared here (cyclic dep — DataFrame → ScanData
# → SourceVariant → ParquetSource → DataFrame). Convenience aliases
# (`read_parquet(path)` / `read_parquet(paths)` / `read_parquet_partitioned`)
# live in the SDK's factories.
# =============================================================================

from std.collections import Optional

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_IN_LIST,
    COL_SIDE_NONE,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_AND,
)
from komira_scan_source.pushdown_gate import arrow_type_has_column_stats
from komira_scan_source.source_like import SourceLike
from komira_plan_expr.partition_pred_pod import PartitionPredicatePod
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod


# =============================================================================
# FNV-1a hash helpers (mirrors `bloom_filter._fnv1a_hash_int64` + the
# `LogicalPlan.fingerprint` String-walk pattern in logical_plan.mojo).
# Local copies live here to avoid pulling collections/ as a dep of source/.
# =============================================================================


@always_inline
def _fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def _hash_string(s: String) -> UInt64:
    """FNV-1a 64-bit hash over a String's bytes. Walks via `as_bytes()`
    (no UnsafePointer in the public surface)."""
    var h: UInt64 = _fnv1a_offset_basis()
    var prime: UInt64 = _fnv1a_prime()
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = h ^ UInt64(b[i])
        h = h * prime
    return h


def _hash_combine(a: UInt64, b: UInt64) -> UInt64:
    """FNV-1a hash_combine: mix two 64-bit hashes via XOR + multiplicative
    prime. Order-sensitive (combine(a,b) != combine(b,a) generally)."""
    return (a ^ b) * _fnv1a_prime()


@always_inline
def _arrow_type_has_parquet_stats(t: ArrowType) -> Bool:
    """True if a column of Arrow type `t` carries min/max statistics in a
    parquet file (and thus a `col <op> literal` predicate over it can
    drive row-group zonemap pruning).

    The type list lives in
    `komira_scan_source.pushdown_gate.arrow_type_has_column_stats`, which is
    the same predicate the declarative `PushdownGate` matcher evaluates. This
    wrapper delegates rather than keeping a second copy — two copies would let
    the concrete source and the gate drift, and a gated arm must answer
    IDENTICALLY to the concrete source.
    """
    return arrow_type_has_column_stats(t)


def _sorted_copy(paths: List[String]) -> List[String]:
    """Return a sorted (lexicographic) copy of `paths`. Used so the
    multi-file fingerprint is independent of the order the caller listed
    the paths in. Small N (file lists, not data) → an
    insertion sort is fine and avoids pulling a sort dep into source/."""
    var n = len(paths)
    var used = List[Bool]()
    for _ in range(n):
        used.append(False)
    var out = List[String]()
    # Selection sort: each pass finds the smallest not-yet-emitted path.
    for _ in range(n):
        var best = -1
        for i in range(n):
            if used[i]:
                continue
            if best < 0 or paths[i] < paths[best]:
                best = i
        used[best] = True
        out.append(String(paths[best]))
    return out^


# =============================================================================
# ParquetSource
# =============================================================================


struct ParquetSource(SourceLike, Movable, Copyable, Deinitable):
    """Concrete SourceLike for parquet file(s) on disk.

    Identity = FNV-1a over the sorted path list + partition-col names +
    representative mtime. Same path-set + same mtime ⇒ same fingerprint
    (cache hit). Any path rewritten / added / removed ⇒ different
    fingerprint ⇒ cache miss (re-optimize against fresh stats).

    The single-file case is `paths == [path]` with empty `partition_cols`
    / `partition_values`. The `path` field is a derived alias = `paths[0]`
    for the call sites that read it (plan_compiler, ScanData ctor,
    plan_display).

    `to_dataframe` is NOT declared (it lives in the SDK's factories). The
    `mtime_ns` parameter defaults to 0.
    """

    var paths: List[String]
    var path: String  # derived: paths[0]. Kept for single-path readers.
    var schema_cached: Schema
    var partition_cols: List[Field]
    var partition_values: List[List[String]]  # [path_idx][partition_col_idx] -> raw value text
    var name: Optional[String]
    var _mtime_ns: UInt64
    # --- Lazy Hive discovery — both defaulted so every eager ctor / factory
    #     is a no-op (False / None). ---
    var hive_dir_scan: Bool
    """Discriminant: when True this is a LAZY dir-scanning Hive source —
    `paths == [base_dir]` (a SINGLE, UN-enumerated directory/glob), `path` is
    that base dir, and `partition_cols` carry the partition schema (probed
    shallowly at plan-BUILD). The leaf data files are NOT enumerated here; the
    engine ctor lists only the surviving partitions via
    `PrunedHiveDiscovery.open_pruned`. `partition_values` is EMPTY for this
    shape (per-path values come from the engine discovery, not the plan).
    False = the eager shape (single file / flat multi-file / eager-Hive)."""
    var hive_predicate: Optional[PartitionPredicatePod]
    """Tier-1 partition-prune POD, attached by the `attach_hive_predicate`
    optimizer pass once the partition filter is known. `Some(empty())` = the
    un-filtered degenerate Hive read (surfaces partition cols, prunes nothing).
    `None` until the pass runs (or for non-dir-scan sources). Only meaningful
    when `hive_dir_scan` is True."""
    # --- The source's FS identity — defaulted to FsDescriptorPod.local() so
    #     every local ctor / factory is a no-op (scheme=FILE, node_id=-1, the
    #     local default). A cloud read sets it to
    #     `FsDescriptorPod.cloud(scheme, bucket, node_id)` with a query-unique
    #     node_id, the scheme being the code komira_source_url maps the
    #     source URL's prefix to; it propagates into the physical
    #     `ParquetSourceData`, which names the one file system that reads it.
    #     Core names NO FS type here — only the identity POD. ---
    var fs_descriptor: FsDescriptorPod
    """Per-source FS identity (scheme + bucket + node_id). Local default
    (node_id=-1) for on-disk reads; a bound node_id for cloud reads. NOT folded
    into the cache fingerprint (FS identity is a materialize-time binding, not
    a plan-shape discriminant)."""

    def __init__(
        out self,
        var path: String,
        var schema: Schema,
        var name: Optional[String] = None,
        mtime_ns: UInt64 = 0,
    ):
        """Single-file constructor.

        Builds a 1-element `paths` list with no partition columns.

        Args:
            path: Parquet file path.
            schema: Parsed data schema (caller responsible for footer-read).
            name: Optional EXPLAIN label; NOT folded into fingerprint.
            mtime_ns: File mtime in nanoseconds-since-epoch. Defaults to 0.
        """
        var single = List[String]()
        single.append(String(path))
        self.paths = single^
        self.path = path^
        self.schema_cached = schema^
        self.partition_cols = List[Field]()
        self.partition_values = List[List[String]]()
        self.name = name^
        self._mtime_ns = mtime_ns
        self.hive_dir_scan = False
        self.hive_predicate = None
        self.fs_descriptor = FsDescriptorPod.local()

    @staticmethod
    def partitioned(
        var paths: List[String],
        var schema: Schema,
        var partition_cols: List[Field],
        var partition_values: List[List[String]],
        var name: Optional[String] = None,
        mtime_ns: UInt64 = 0,
    ) raises -> Self:
        """Multi-file / Hive-partitioned constructor.

        Args:
            paths: One-or-more parquet file paths. Non-empty (raises on
                empty — an empty path-set is a caller error, not an empty
                relation).
            schema: The DATA schema (columns in the files; does NOT include
                the Hive partition columns).
            partition_cols: Hive partition columns (name + inferred type).
                May be empty (a plain multi-file scan with no partitioning).
            partition_values: Per-path raw value text for each partition
                col. `len(partition_values) == len(paths)` and each inner
                list has `len(partition_cols)` entries — OR `partition_cols`
                is empty and `partition_values` is empty. Raises on a shape
                mismatch.
            name: Optional EXPLAIN label.
            mtime_ns: Representative file mtime.

        Returns:
            A ParquetSource carrying the full path list + partition metadata.
        """
        if len(paths) == 0:
            raise Error(
                "ParquetSource.partitioned: empty path list (a partitioned"
                " scan must reference at least one file)"
            )
        if len(partition_cols) == 0:
            # Plain multi-file: partition_values must be empty.
            if len(partition_values) != 0:
                raise Error(
                    "ParquetSource.partitioned: partition_values must be"
                    " empty when partition_cols is empty"
                )
        else:
            if len(partition_values) != len(paths):
                raise Error(
                    "ParquetSource.partitioned: partition_values has "
                    + String(len(partition_values))
                    + " rows but there are "
                    + String(len(paths))
                    + " paths"
                )
            for i in range(len(partition_values)):
                if len(partition_values[i]) != len(partition_cols):
                    raise Error(
                        "ParquetSource.partitioned: partition_values["
                        + String(i)
                        + "] has "
                        + String(len(partition_values[i]))
                        + " entries but there are "
                        + String(len(partition_cols))
                        + " partition columns"
                    )
        var self = ParquetSource.__new_unchecked()
        self.path = String(paths[0])
        self.paths = paths^
        self.schema_cached = schema^
        self.partition_cols = partition_cols^
        self.partition_values = partition_values^
        self.name = name^
        self._mtime_ns = mtime_ns
        self.hive_dir_scan = False
        self.hive_predicate = None
        return self^

    @staticmethod
    def dir_scan_hive(
        var base_dir: String,
        var schema: Schema,
        var partition_cols: List[Field],
        var name: Optional[String] = None,
        mtime_ns: UInt64 = 0,
    ) raises -> Self:
        """Lazy dir-scanning Hive constructor.

        Builds an UN-enumerated dir-scan source: `paths == [base_dir]` (a
        SINGLE base directory/glob, NOT the expanded leaf-file set), the DATA
        `schema`, and the partition-column schema (`partition_cols`, name+type,
        probed shallowly at plan-BUILD). `partition_values` is EMPTY — the
        per-path constant values are surfaced by the engine's
        `PrunedHiveDiscovery` at materialize time, not by the plan. The
        `attach_hive_predicate` optimizer pass later sets `hive_predicate` to the
        Tier-1 prune POD; until then it is `None` (the lowering treats `None`
        on a dir-scan source as `empty()` — pruning nothing).

        Args:
            base_dir: The Hive base directory / glob (un-expanded).
            schema: The DATA schema (file columns; does NOT include partition cols).
            partition_cols: The Hive partition columns (name + inferred type).
            name: Optional EXPLAIN label.
            mtime_ns: Representative mtime.

        Raises:
            On an empty `base_dir` (a caller error) or empty `partition_cols`
            (a dir-scan-Hive source with no partition cols is meaningless — the
            caller should build a plain single-source plan instead).
        """
        if base_dir.byte_length() == 0:
            raise Error(
                "ParquetSource.dir_scan_hive: empty base_dir (a dir-scan Hive"
                " source must reference a base directory)"
            )
        if len(partition_cols) == 0:
            raise Error(
                "ParquetSource.dir_scan_hive: empty partition_cols (a dir-scan"
                " Hive source must carry >= 1 partition column; use the plain"
                " single-source plan for a non-Hive directory)"
            )
        var self = ParquetSource.__new_unchecked()
        self.path = String(base_dir)
        var single = List[String]()
        single.append(base_dir^)
        self.paths = single^
        self.schema_cached = schema^
        self.partition_cols = partition_cols^
        self.partition_values = List[List[String]]()
        self.name = name^
        self._mtime_ns = mtime_ns
        self.hive_dir_scan = True
        self.hive_predicate = None
        return self^

    @always_inline
    def is_dir_scan_hive(self) -> Bool:
        """True iff this is a lazy dir-scanning Hive source (the
        discriminant the optimizer / lowering / materialize sites branch on)."""
        return self.hive_dir_scan

    def with_hive_predicate(self, var pred: PartitionPredicatePod) raises -> Self:
        """Return a copy of this dir-scan-Hive source with `hive_predicate` set
        to `pred` (the Tier-1 prune POD). Used by the `attach_hive_predicate`
        optimizer pass. Raises if `self` is not a dir-scan-Hive source (the POD
        only attaches to the lazy shape)."""
        if not self.hive_dir_scan:
            raise Error(
                "ParquetSource.with_hive_predicate: not a dir-scan-Hive source"
                " (the Tier-1 prune POD only attaches to the lazy shape)"
            )
        var out = self.copy()
        out.hive_predicate = Optional[PartitionPredicatePod](pred^)
        return out^

    @staticmethod
    def __new_unchecked() -> Self:
        """Internal: zero-state Self for the `partitioned` factory to fill.
        Not part of the public surface (double-underscore)."""
        var single = List[String]()
        single.append(String(""))
        return ParquetSource(String(""), Schema(), None, 0)

    def copy(self) -> Self:
        """Explicit deep clone. Schema/Field are auto-synth Copyable.
        Optional[String].copy() handles the optional name field. `List`s of
        `String`/`Field` deep-clone element-wise."""
        var name_copy: Optional[String] = None
        if self.name:
            name_copy = Optional(String(self.name.value()))
        var paths_copy = List[String]()
        for i in range(len(self.paths)):
            paths_copy.append(String(self.paths[i]))
        var pcols_copy = List[Field]()
        for i in range(len(self.partition_cols)):
            pcols_copy.append(self.partition_cols[i].copy())
        var pvals_copy = List[List[String]]()
        for i in range(len(self.partition_values)):
            var row = List[String]()
            for j in range(len(self.partition_values[i])):
                row.append(String(self.partition_values[i][j]))
            pvals_copy.append(row^)
        var pred_copy: Optional[PartitionPredicatePod] = None
        if self.hive_predicate:
            pred_copy = Optional(self.hive_predicate.value().copy())
        var out = ParquetSource.__new_unchecked()
        out.path = String(self.path)
        out.paths = paths_copy^
        out.schema_cached = self.schema_cached.copy()
        out.partition_cols = pcols_copy^
        out.partition_values = pvals_copy^
        out.name = name_copy^
        out._mtime_ns = self._mtime_ns
        out.hive_dir_scan = self.hive_dir_scan
        out.hive_predicate = pred_copy^
        out.fs_descriptor = self.fs_descriptor.copy()
        return out^

    def with_fs_descriptor(self, fs_descriptor: FsDescriptorPod) -> Self:
        """Return a copy of this source with `fs_descriptor` set (the
        per-source FS identity POD naming the source's scheme, bucket and
        node_id). Works for ANY source shape (single file / partitioned /
        dir-scan-Hive) — unlike `with_hive_predicate`, FS identity attaches to
        every cloud read."""
        var out = self.copy()
        out.fs_descriptor = fs_descriptor.copy()
        return out^

    # --- Multi-file / partition accessors ---

    def is_multi_file(self) -> Bool:
        """True when this source spans more than one parquet file."""
        return len(self.paths) > 1

    def is_partitioned(self) -> Bool:
        """True when this source carries Hive partition columns."""
        return len(self.partition_cols) > 0

    # --- SourceLike trait conformance ---

    def schema(self) -> Schema:
        """DATA schema (eager copy of cached state — no I/O). NOTE: this is
        the schema of the columns in the parquet files; the Hive partition
        columns are appended by the engine at scan time, so the FULL output
        schema of a partitioned scan is `schema() + partition_cols`."""
        return self.schema_cached.copy()

    def estimate_rows(self) -> Int:
        """Returns -1 (unknown). A footer row-count read (summing across all
        paths) can fill it."""
        return -1

    def fingerprint(self) -> UInt64:
        """Stable identity = FNV-1a over the sorted, length-prefixed path
        list + partition-col names + representative mtime.

        Order-independent over `paths` (sorted first), so two
        `ParquetSource.partitioned([a, b], ...)` and
        `ParquetSource.partitioned([b, a], ...)` get the same fingerprint
        clones (the cache-discrimination contract — see the SourceLike
        `fingerprint` docstring in `source_like.mojo`).
        """
        var sorted_paths = _sorted_copy(self.paths)
        # Hash the path count first (so [a] vs [a, b] discriminate cleanly
        # even before content), then each length-prefixed path.
        var h: UInt64 = _fnv1a_offset_basis()
        h = _hash_combine(h, UInt64(len(sorted_paths)))
        for i in range(len(sorted_paths)):
            ref p = sorted_paths[i]
            h = _hash_combine(h, UInt64(p.byte_length()))
            h = _hash_combine(h, _hash_string(p))
        # Fold partition-col names (count + each name).
        h = _hash_combine(h, UInt64(len(self.partition_cols)))
        for i in range(len(self.partition_cols)):
            h = _hash_combine(h, _hash_string(self.partition_cols[i].name))
        # Fold the representative mtime (file-rewrite invalidation).
        h = _hash_combine(h, self._mtime_ns)
        return h

    # --- Per-predicate pushdown query ---

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Return `True` for predicates this ParquetSource can usefully
        absorb into its scan (row-group zonemap pruning + partition-col
        path pruning); `False` otherwise.

        Accepted (return `True`):
          * `col <op> literal` / `literal <op> col` where
            `op ∈ {==, !=, <, <=, >, >=}` and `col` is a bare
            (`COL_SIDE_NONE`) column reference present in either the
            DATA schema or the Hive `partition_cols`, of a type with
            parquet column statistics (Int*/UInt*/Float*/String/
            Large-String/Date/Timestamp/Decimal128/Bool). These are the
            shapes the parquet RG-pruning code (`test_rg_pruning` /
            `batch_reader.read_columns_filtered`) and the
            `partition_prune_scans` rule can actually use.
          * `IN (lit, ...)` where the tested expression is such a bare
            stat-friendly column reference (the engine applies it as a
            row-wise filter; `optimizer_symmetric_or` emits this shape).
          * `A AND B` where BOTH `A` and `B` are pushable (recursion).

        Rejected (return `False`): OR-trees, BETWEEN, string-ops
        (LIKE etc.), CAST/arithmetic on the column side, agg/window
        functions, side-qualified col-refs, col-refs not in the schema,
        and any expression tag this method does not recognize. Such a
        predicate stays as a `Filter` node above the scan — correct, and
        for parquet there is no decode benefit to folding it in (the
        RG-pruning code only consults conjunctive col-op-literal terms).

        A possible refinement is the tri-state `Inexact` form (push a
        best-effort approximation, keep a re-checking Filter) — see the
        SourceLike trait docstring.
        """
        return self._pushdown_supported(predicate)

    def _pushdown_supported(self, predicate: Expr) -> Bool:
        """Recursive predicate-shape classifier — see
        `supports_filter_pushdown`. Pure (no I/O); reads only the cached
        schema + partition_cols."""
        if predicate.tag == EXPR_BINARY_OP:
            var op = predicate.binary_op()
            if op == BIN_AND:
                # Conjunction: pushable iff BOTH sides are pushable.
                return self._pushdown_supported(
                    predicate.binary_left_ref()
                ) and self._pushdown_supported(predicate.binary_right_ref())
            elif (
                op == BIN_EQ
                or op == BIN_NE
                or op == BIN_LT
                or op == BIN_LE
                or op == BIN_GT
                or op == BIN_GE
            ):
                # Comparison: one side a bare stat-friendly col-ref, the
                # other side a literal (order-insensitive).
                return self._is_colop_literal(
                    predicate.binary_left_ref(), predicate.binary_right_ref()
                ) or self._is_colop_literal(
                    predicate.binary_right_ref(), predicate.binary_left_ref()
                )
            else:
                # Arithmetic / OR / other binary ops on the predicate
                # boundary: not a zonemap-friendly shape.
                return False
        elif predicate.tag == EXPR_IN_LIST:
            # `col IN (...)`: pushable iff the tested expr is a bare
            # stat-friendly col-ref. (Values are scalar literals.)
            return self._is_stat_friendly_colref(predicate.in_list_child_ref())
        # Bare col-ref / literal / unary / cast / string-op / between /
        # when / agg / window / correlated-subquery / col-idx: not a
        # zonemap-friendly conjunct on its own.
        return False

    def _is_colop_literal(self, lhs: Expr, rhs: Expr) -> Bool:
        """True if `lhs` is a bare stat-friendly column reference and
        `rhs` is a literal."""
        if rhs.tag != EXPR_LITERAL:
            return False
        return self._is_stat_friendly_colref(lhs)

    def _is_stat_friendly_colref(self, e: Expr) -> Bool:
        """True if `e` is a bare (`COL_SIDE_NONE`) column reference whose
        name is present in the DATA schema or the Hive partition columns,
        AND that column's Arrow type carries parquet statistics."""
        if e.tag != EXPR_COL_REF:
            return False
        if e.col_ref_side() != COL_SIDE_NONE:
            return False
        var name = e.col_ref_name()
        # DATA schema: a name match must also be a stat-friendly type.
        for i in range(self.schema_cached.num_columns()):
            if self.schema_cached.field_name(i) == name:
                return _arrow_type_has_parquet_stats(
                    self.schema_cached.field_arrow_type(i)
                )
        # Hive partition columns: a partition predicate (`col == literal`)
        # is consumed by `partition_prune_scans` regardless of the
        # inferred partition-col type, so accept any partition-col name.
        for i in range(len(self.partition_cols)):
            if self.partition_cols[i].name == name:
                return True
        return False
