# =============================================================================
# ParquetReadOptions — the read_parquet options POD (RFC §7.2).
# =============================================================================
#
# The SDK-layer read options POD threaded through both
# `read_parquet` surfaces (untyped `ctx.read_parquet(path, options)` + typed
# `read_parquet[S, ID](ctx, path, options)`). Defaults reproduce TODAY's
# behavior so every existing caller (explicit file lists, single files, flat
# globs) is UNCHANGED — the POD is omitted at the callsite and default-
# constructs.
#
# RFC: the glob discovery design §7.2. The POD is a
# parquet-SDK concern (it carries the by-name-union default + the Hive auto-
# detect default + the empty-glob policy), distinct from the discovery-layer
# `GlobDiscoveryOptions` (`komira_async.fs.file_discovery`) which carries ONLY
# the empty-match policy the glob engine needs.
#
# This file imports only `komira_plan_expr.expr` and the stdlib. The
# `allow_empty_glob` -> `GlobDiscoveryOptions` mapping is not a method here,
# so the discovery layer is not among its imports.
#
# POD discipline: the discovery knobs are all `Bool`, all defaulted. The POD is
# `Movable` + `Deinitable`. No UnsafePointer, no wildcard origin.
#
# The read-time `partition_filter` field carries an
# OPTIONAL partition predicate (`col("dt") == lit("X")`) so the cloud Hive
# prune-at-prefix (the marquee cloud win) can be expressed AT READ TIME. The
# cloud arm inline-materializes (A-erase) so it sees ONLY predicates
# present on the plan at the read seam — a chained `.filter()` after the
# FS-erased DataFrame returns is too late. `partition_filter` supplies that
# read-time channel: it is wrapped as a `Filter` over the lazy dir-scan plan at
# plan-build, and the existing `attach_hive_predicate` optimizer pass splits it
# (G.7 `split_partition_predicate`) into the Tier-1 partition POD (pruned at the
# LIST prefix) + the Tier-2 DATA residual (a row-group/page Filter). So a
# `partition_filter` referencing a NON-partition (data) column does NOT error —
# the G.7 split routes it to the Tier-2 residual (the lenient, composable
# contract: partition cols prune, data cols filter).
#
# WHY `Optional[Expr]` (not the POD): the user writes the predicate as an
# `Expr` (`col == lit`) — ergonomic — and the schema-aware split needs the
# partition schema, which is not known until the dir is probed. Storing the
# RAW `Expr` defers the split to optimize-time (where the dir_scan_hive source
# carries the partition schema) and reuses `attach_hive_predicate` verbatim, so
# no new split logic and no chicken-and-egg. `Expr` is `Movable` (a recursive
# `OwnedPointer[Expr]` tree, heap-owning) but NOT `Copyable` — so this struct is
# `Movable` + explicit `.copy()` (NOT trait-`Copyable`). It is never placed in a
# byte-slab element, so the heap-owning `Expr` field is not a gap6 hazard.
# =============================================================================

from std.collections import Optional

from komira_plan_expr.expr import Expr


struct ParquetReadOptions(Movable, Deinitable):
    """User-facing options for `read_parquet` (untyped + typed).

    Field set (RFC §7.2):
      var union_by_name: Bool = True
        [v3 default] For the UNTYPED multi-file path, the result schema is the
        by-name UNION of all surviving footers (a file lacking a union column
        → that column NULL for its rows; cross-file type conflict → ERROR).
        This is the campaign default (RESOLVED — union-by-name is IN v1,
        not an opt-in). Set `False` to request the tighter same-schema-only
        contract (require identical footers across files; raise on any
        name/order/type divergence). The by-name RESOLUTION (the §6.0
        corruption fix) is ALWAYS on regardless of this flag — `False` still
        resolves by name, it merely additionally requires the names/types to
        match across files rather than unioning. There is no longer a
        "positional" mode; the positional decode is the bug v3 removed.

        NOTE: `union_by_name` does NOT apply to the TYPED `read_parquet[S, ID]`
        path — the typed schema is exactly `S` (+ partition cols); the typed
        path validates `S ⊆ EVERY file` by name and ERRORs on a missing `S`
        column rather than NULL-filling (a declaration is an assertion of
        presence — RFC §7.3).

      var allow_empty_glob: Bool = False
        [RFC §2.5] Fail-Fast: a glob/dir spec matching ZERO files RAISES by
        default (a typo'd glob silently returning an empty frame is a classic
        foot-gun). Set `True` to opt out (the caller validates emptiness).
        Maps down into `GlobDiscoveryOptions.allow_empty_glob`.

      var hive_partitioning: Bool = True
        [RFC §5.6 / §7.2, PE recommendation: auto-detect ON] When True
        (default), a Hive-partitioned layout (key=value path segments present)
        is auto-detected: the partition columns are derived from the path and
        surfaced as output columns (G.5/G.8), and a partition-column filter is
        pruned at the list prefix (G.5/G.7). When False, the layout is read as
        a plain multi-file scan (no partition columns, no prune) — the user
        opts out of surprise partition columns.

    Recursion is INFERRED from the glob (`**` → recursive); there is no explicit
    recursion flag. Partition types are inferred by default (the G.5 type-probe
    DATE→TIMESTAMP→BIGINT→VARCHAR); an explicit `hive_types` override is the
    follow-on (not in v1).
    """

    var union_by_name: Bool
    var allow_empty_glob: Bool
    var hive_partitioning: Bool
    var partition_filter: Optional[Expr]
    """The read-time partition predicate
    (`col("dt") == lit("X")`), or `None`. When `Some` AND the read is a Hive
    dir-scan, the predicate is wrapped as a `Filter` over the lazy dir-scan
    plan at plan-build; the existing `attach_hive_predicate` optimizer pass
    splits it into the Tier-1 partition POD (pruned at the LIST prefix — the
    marquee cloud win) + the Tier-2 DATA residual (a row-group/page Filter).
    A predicate referencing a non-partition column is NOT an error — the G.7
    split routes it to the Tier-2 residual. Default `None` (every existing
    caller unchanged; the chained-`.filter()` local prune path is unaffected).
    NOTE: `Expr` is `Movable`/heap-owning (a recursive `OwnedPointer[Expr]`
    tree) but NOT `Copyable`, which is why this struct is `Movable` +
    explicit `.copy()` rather than trait-`Copyable`."""
    var lazy_hive_lowering: Bool
    """Internal. When True (the UNTYPED default), a detected Hive
    read is lowered LAZILY: an un-enumerated dir-scan `ParquetSource` carrying
    the partition schema + (post-optimize) the Tier-1 prune POD, so the engine
    ctor lists only the surviving partitions (G.12b `open_pruned`). When False,
    a detected Hive read is lowered EAGERLY (today's `ParquetSource.partitioned`
    full-path enumeration + `partition_prune_scans` post-list prune). The TYPED
    `read_parquet[S, ID]` path forces this False until G.12a-typed lands (the
    typed G.9b all-files validation is gated on the eager full set for now —
    contract §6.4 / R-3). This is an internal knob, not user-facing."""

    def __init__(
        out self,
        union_by_name: Bool,
        allow_empty_glob: Bool,
        hive_partitioning: Bool,
        lazy_hive_lowering: Bool = True,
        var partition_filter: Optional[Expr] = None,
    ):
        """Construct the options POD. The first three are user-facing; the
        fourth (`lazy_hive_lowering`) is an INTERNAL G.12a knob defaulted True
        (untyped lazy Hive lowering) — existing 3-arg construction sites are
        UNCHANGED. The fifth (`partition_filter`) is the
        read-time partition predicate, defaulted `None`. The typed path
        overrides `lazy_hive_lowering` via `with_eager_hive_lowering`."""
        self.union_by_name = union_by_name
        self.allow_empty_glob = allow_empty_glob
        self.hive_partitioning = hive_partitioning
        self.lazy_hive_lowering = lazy_hive_lowering
        self.partition_filter = partition_filter^

    def copy(self) -> ParquetReadOptions:
        """Explicit deep copy (`Expr` is `Movable` not `Copyable`, so this
        struct cannot conform to trait-`Copyable`; the recursive `Expr` tree is
        cloned via its own `.copy()`)."""
        var pf_copy: Optional[Expr] = None
        if self.partition_filter:
            pf_copy = Optional(self.partition_filter.value().copy())
        return ParquetReadOptions(
            union_by_name=self.union_by_name,
            allow_empty_glob=self.allow_empty_glob,
            hive_partitioning=self.hive_partitioning,
            lazy_hive_lowering=self.lazy_hive_lowering,
            partition_filter=pf_copy^,
        )

    @staticmethod
    def default() -> ParquetReadOptions:
        """The campaign-default options (RFC §7.2). Every field at its default
        reproduces TODAY's behavior for non-Hive single-file / flat-glob reads,
        and the v1 union-by-name + Hive auto-detect + (G.12a) lazy-Hive-lowering
        contract for multi-file / Hive reads. `partition_filter` defaults
        `None` (no read-time prune)."""
        return ParquetReadOptions(
            union_by_name=True,
            allow_empty_glob=False,
            hive_partitioning=True,
            lazy_hive_lowering=True,
            partition_filter=None,
        )

    def with_eager_hive_lowering(self) -> ParquetReadOptions:
        """Return a copy with `lazy_hive_lowering` forced OFF (G.12a). The TYPED
        `read_parquet[S, ID]` path calls this so a Hive read stays on the eager
        `ParquetSource.partitioned` path (the G.9b all-files validation is gated
        on the eager full set until G.12a-typed). Preserves
        `partition_filter`."""
        var pf_copy: Optional[Expr] = None
        if self.partition_filter:
            pf_copy = Optional(self.partition_filter.value().copy())
        return ParquetReadOptions(
            union_by_name=self.union_by_name,
            allow_empty_glob=self.allow_empty_glob,
            hive_partitioning=self.hive_partitioning,
            lazy_hive_lowering=False,
            partition_filter=pf_copy^,
        )

    def with_partition_filter(self, var predicate: Expr) -> ParquetReadOptions:
        """Return a copy carrying `partition_filter = Some(predicate)`
        Ergonomic builder for the read-time partition prune:
        `ParquetReadOptions.default().with_partition_filter(col("dt") == lit("X"))`."""
        return ParquetReadOptions(
            union_by_name=self.union_by_name,
            allow_empty_glob=self.allow_empty_glob,
            hive_partitioning=self.hive_partitioning,
            lazy_hive_lowering=self.lazy_hive_lowering,
            partition_filter=Optional(predicate^),
        )

