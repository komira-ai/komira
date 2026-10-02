# =============================================================================
# komira_fs.file_discovery — FileDiscovery trait + EagerGlobDiscovery
#
# =============================================================================
# The `FileDiscovery` TRAIT + the first concrete impl `EagerGlobDiscovery`,
# built over the concrete `PathDiscovery` (path_discovery.mojo). The trait
# declares the discovery contract (capability flag + materialized-path
# access + the partition-pruning HOOK); `EagerGlobDiscovery` carries the
# single-file / directory-scan / glob-pattern modes (the `PathDiscovery` body
# PLUS a glob branch built on `komira_fs.glob`).
#
# `PrunedHiveDiscovery` (the partition-pruning-aware impl) populates the
# partition hooks this trait declares. `EagerGlobDiscovery` returns EMPTY for
# both partition hooks (it is not partition-aware) — exactly the no-op
# contract the trait specifies.
#
# ---------------------------------------------------------------------------
# Pointer discipline:
#   * NO UnsafePointer in any trait method signature or impl method signature.
#   * The FS generic is METHOD-level (`open[FS: FileSystem]`), NOT a struct
#     type-param — exactly the `PathDiscovery` shape. So `EagerGlobDiscovery`
#     holds ZERO FS state; its fields are owned typed values only.
#   * destroy-recreate safety: the trait monomorphizes to a CONCRETE impl when
#     bound as `Self.DISC` on a source (comptime trait bound — no vtable, no
#     wildcard origin, no type erasure — same as a source's existing
#     `var _fs: Self.FS` / `var _factory: Self.RF` fields). `EagerGlobDiscovery`'s
#     only owning field is `Slab[String]` (the same byte-slab-safe shape
#     `PathDiscovery` uses). The two partition POD value types
#     (`PartitionValues` / `PartitionSchema`) are NOT stored by
#     `EagerGlobDiscovery` (its hooks return fresh empties), so they introduce
#     ZERO byte-slab element. `PrunedHiveDiscovery`, which DOES store them,
#     uses the arena-index-handle shape (offsets into a backing
#     `Slab[String]`), NOT a per-element `List` inside a byte-slab.
# =============================================================================

from komira_fs.file_system import FileSystem
from komira_fs.glob import (
    has_glob,
    brace_expand,
    split_static_prefix,
    glob_match_path,
)
from komira_core.collections.slab import Slab
from komira_core.arrow.arrow_types import ArrowType


# =============================================================================
# Partition value/schema POD shapes.
# =============================================================================
# Small typed value types for the partition-pruning hook. They are EMPTY by
# default; the Hive-partition derivation populates them. They are owned,
# Copyable+Movable value types — NO
# UnsafePointer, NO wildcard origin. `EagerGlobDiscovery` never stores them
# (its hooks return fresh empties); when `PrunedHiveDiscovery` stores them per
# file it MUST follow arena-handle shape (NOT a List inside a
# byte-slab) — flagged in this module header.
# =============================================================================


@fieldwise_init
struct PartitionValues(Copyable, Movable, Deinitable):
    """Path-derived partition `key=value` pairs for one file.

    `EagerGlobDiscovery` is not partition-aware, so `partition_values_at`
    returns `PartitionValues.empty()`. `PrunedHiveDiscovery` populates the
    parsed `(key, value)` pairs from
    the file's path segments.

    The `keys` / `values` parallel lists model the ordered `(key, value)` set.
    They are plain owned `List[String]` here because `PartitionValues` is a
    by-value return type, NOT a byte-slab element in `EagerGlobDiscovery`. The
    arena-handle constraint applies ONLY to `PrunedHiveDiscovery`'s
    per-file STORAGE, where these would otherwise land inside a `Slab` element.
    """

    var keys: List[String]
    var values: List[String]

    @staticmethod
    def empty() -> PartitionValues:
        """The no-partition value (EagerGlobDiscovery / non-Hive layouts)."""
        return PartitionValues(keys=List[String](), values=List[String]())

    @always_inline
    def num_pairs(self) -> Int:
        """Number of `(key, value)` partition pairs. 0 for the empty value."""
        return len(self.keys)


@fieldwise_init
struct PartitionSchema(Copyable, Movable, Deinitable):
    """The derived partition-column schema (names only; a type matrix is a
    separate step).

    `EagerGlobDiscovery.partition_schema` returns `PartitionSchema.empty()`. A
    multi-consumer source's ctor reads it once to extend the output schema; an
    empty schema appends zero partition columns.

    `names` is a plain owned `List[String]` — a by-value return type, not a
    byte-slab element. A type matrix would add a parallel typed
    representation for the inferred `DataType`s (DATE/TIMESTAMP/BIGINT/VARCHAR
    probe).
    """

    var names: List[String]

    @staticmethod
    def empty() -> PartitionSchema:
        """The no-partition schema (EagerGlobDiscovery / non-Hive layouts)."""
        return PartitionSchema(names=List[String]())

    @always_inline
    def num_columns(self) -> Int:
        """Number of partition columns. 0 for the empty schema."""
        return len(self.names)


# =============================================================================
# GlobDiscoveryOptions POD (the discovery-local options carry).
# =============================================================================
# A parquet reader has its own read-options POD (union_by_name / hive /
# empty-glob). The discovery layer needs ONLY the empty-match policy, so it
# carries a minimal self-contained POD here, and a reader maps its
# `allow_empty_glob` into this. Keeping it minimal avoids a premature
# cross-module dependency (the discovery layer lives in `komira_async`, the
# parquet read options in `komira_parquet`).
# =============================================================================


@fieldwise_init
struct GlobDiscoveryOptions(Copyable, Movable, Deinitable):
    """Discovery-layer options for `EagerGlobDiscovery.open`.

    Field set:
      var allow_empty_glob: Bool
        When False, a glob/dir spec
        that matches ZERO files RAISES. When True, an empty match yields an
        empty discovery (the caller validates / handles emptiness).
    """

    var allow_empty_glob: Bool

    @staticmethod
    def default() -> GlobDiscoveryOptions:
        """Defaults reproduce Fail-Fast policy: empty glob raises."""
        return GlobDiscoveryOptions(allow_empty_glob=False)


# =============================================================================
# The FileDiscovery trait.
# =============================================================================


trait FileDiscovery(Movable, Deinitable):
    """The discovery contract: a strategy that resolves a `path_spec` (single
    file / directory / glob) into a materialized, lexically-ordered file set,
    and exposes the partition-pruning HOOK (populated by partition-aware
    impls, empty otherwise).

    Construction is NOT on the trait — each impl has its own static `open`
    with the args it needs (the eager impl takes no predicate; the future
    `PrunedHiveDiscovery` takes the partition predicate). Mojo traits cannot
    carry impl-specific static factories cleanly. The FS generic is
    METHOD-level on each impl's `open[FS]`, so ONE impl spans
    LocalFs/S3Fs/GcsFs/AzureFs.

    No `UnsafePointer` anywhere in the surface — `Bool`, `Int`, `String`, and
    the two value PODs (`PartitionValues` / `PartitionSchema`). Pointer
    discipline upheld.
    """

    # ---- Construction (the uniform default-options factory) ------------------
    # a uniform `open[FS](mut fs, path_spec)` factory IS
    # declared on the trait so the `ColumnarMultiConsumerSource` ctor can
    # construct `Self.DISC` generically from `(fs, path_spec)` (the source binds
    # `DISC` at the alias chain; the ctor does NOT know the concrete impl). The
    # eager impl globs/dir-scans/single-files; a future `PrunedHiveDiscovery`
    # provides this predicate-FREE form (no pruning) PLUS its own
    # predicate-taking `open_pruned` static method (NOT on the trait —:
    # impl-specific factories with extra args stay off the trait). So the trait
    # carries ONLY the one uniform no-extra-arg factory the source needs.
    @staticmethod
    def open[FS: FileSystem](mut fs: FS, path_spec: String) raises -> Self:
        """Resolve `path_spec` (single file / directory / glob) into a
        materialized, lexically-ordered file set, using default options
        (`allow_empty_glob=False` — empty glob/dir RAISES). The uniform factory
        the `MultiConsumerSource` ctor dispatches over to build `Self.DISC`."""
        ...

    # ---- Capability flag (comptime-checkable) -------------------------------
    @staticmethod
    def is_lazy() -> Bool:
        """False for v1's eager impls (paths fully materialized at `open`);
        True for the future `StreamingGlobDiscovery` (paths produced
        incrementally). Lets the source choose its open-vs-iterate dance
        without a runtime branch in the eager case."""
        ...

    # ---- Path access (the materialized contract) ----------------------------
    def num_paths(self) -> Int:
        """Number of discovered paths (post-prune for partition-aware impls)."""
        ...

    def path_at(self, idx: Int) raises -> String:
        """The path at `idx` as an owned String. Caller asserts
        `idx < num_paths()`."""
        ...

    # ---- The partition-pruning hook (no-op for the eager-glob impl) ---------
    def partition_values_at(self, idx: Int) raises -> PartitionValues:
        """Path-derived partition `key=value`s for file `idx`. EMPTY for
        non-Hive layouts / `EagerGlobDiscovery`. Used by the source operator
        to materialize partition columns and by the post-listing filter
        fold."""
        ...

    def partition_schema(self) -> PartitionSchema:
        """The derived partition-column schema (names + types). EMPTY for
        `EagerGlobDiscovery`. Read once by `MultiConsumerSource`'s ctor to
        extend the output schema."""
        ...

    # ---- typed-partition surface -----------------------------
    # The source operator materializes partition columns as constant
    # vectors cast to their DECLARED type, appended to the output schema after
    # the data columns. These three hooks expose, generically via `Self.DISC`,
    # the partition column COUNT, the per-column declared TYPE, and the per-
    # column NAME. `EagerGlobDiscovery` returns 0 / STRING / "" (no partition
    # columns — non-Hive layouts append nothing, today's behavior unchanged).
    # `PrunedHiveDiscovery` returns its inferred/declared partition schema.
    def num_partition_cols(self) -> Int:
        """Number of Hive partition columns the source must append as constant
        columns. 0 for `EagerGlobDiscovery` / non-Hive layouts."""
        ...

    def partition_col_type_at(self, idx: Int) -> ArrowType:
        """The DECLARED/inferred ArrowType of partition column `idx`. Governs
        the constant-fill cast. Caller asserts
        `idx < num_partition_cols()`."""
        ...

    def partition_col_name_at(self, idx: Int) -> String:
        """The NAME of partition column `idx`. The constant column is appended
        to the output schema under this name. Caller asserts
        `idx < num_partition_cols()`."""
        ...


# =============================================================================
# EagerGlobDiscovery: single-file / directory-scan / glob, eager listing.
# =============================================================================


@fieldwise_init
struct EagerGlobDiscovery(FileDiscovery, Movable, Deinitable):
    """Eager file discovery: single-file / directory-scan / glob-pattern, with
    all paths materialized + lexically sorted at `open` time. The
    `PathDiscovery` body PLUS the glob engine.

    Field set:
      var _paths: Slab[String]
        Owned, lexically-sorted path strings. Length-1 in single-file mode.
        Same byte-slab-safe shape `PathDiscovery` used; safe across destroy-recreate.

    NOT partition-aware: `partition_values_at` returns `PartitionValues.empty()`
    and `partition_schema` returns `PartitionSchema.empty()`. The Hive impl is
    `PrunedHiveDiscovery`.
    """

    var _paths: Slab[String]

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    @staticmethod
    def open[
        FS: FileSystem
    ](mut fs: FS, path_spec: String) raises -> EagerGlobDiscovery:
        """Open with default options (`allow_empty_glob=False` — empty glob
        raises). See `open_with_options` for the full mode-detection contract."""
        return EagerGlobDiscovery.open_with_options(
            fs, path_spec, GlobDiscoveryOptions.default()
        )

    @staticmethod
    def open_with_options[
        FS: FileSystem
    ](
        mut fs: FS, path_spec: String, options: GlobDiscoveryOptions
    ) raises -> EagerGlobDiscovery:
        """Auto-detect single-file / directory / glob mode, materialize the
        path set, lexically sort it, and apply the empty-match policy.

        Mode detection:
          1. `has_glob(path_spec)` -> GLOB mode:
             `brace_expand` -> for each expanded pattern,
             `split_static_prefix` -> `fs.list(static_prefix)` -> keep paths
             that `glob_match_path(pattern, path)`. Aggregate + dedupe.
          2. else `fs.is_dir(path_spec)` -> DIRECTORY mode: `fs.list(path_spec)`
             (the single-path behavior).
          3. else -> SINGLE-FILE mode: a one-element set `[path_spec]`.

        The final set is LEXICALLY SORTED (deterministic output
        order; also load-bearing for `union_by_name` first-seen column
        order). The explicit-list ctor (`open_paths`) preserves caller order.

        Empty-match policy: in GLOB or DIRECTORY mode, a zero-file
        result RAISES unless `options.allow_empty_glob` is True. SINGLE-FILE
        mode never produces an empty set (the literal path is always present;
        a non-existent file surfaces at open/footer time, not here — matching
        the `PathDiscovery` contract).

        Recursion is INFERRED from the glob (`**` in the residual chooses
        recursive vs shallow listing at the `fs.list` layer —, wired
); there is no recursion flag.

        Args:
            fs:        FileSystem-conformer instance. Mutable receiver per
                       `FileSystem`'s mutability contract; `is_dir` + `list`
                       are sync.
            path_spec: A file path, a directory prefix, or a glob pattern.
            options:   Discovery options (empty-glob policy).

        Returns:
            An `EagerGlobDiscovery` with `_paths` populated + sorted.

        Raises:
            * On I/O failure of `is_dir` / `list`.
            * On a >1-`**` glob (via `glob_match_path`).
            * On an empty glob/dir result when `allow_empty_glob` is False.
        """
        var matched = List[String]()

        if has_glob(path_spec):
            # ---- GLOB mode ----
            var patterns = brace_expand(path_spec)
            for pi in range(len(patterns)):
                var pattern = patterns[pi].copy()
                var split = split_static_prefix(pattern)
                var static_prefix = split[0].copy()
                # List candidates under the static prefix (object stores have
                # no server-side glob; the residual is filtered client-side).
                var candidates = fs.list(static_prefix)
                for ci in range(len(candidates)):
                    var cand = candidates[ci].copy()
                    if glob_match_path(pattern, cand):
                        _append_deduped(matched, cand^)
            _sort_and_check_nonempty(matched, path_spec, options, True)
        elif _is_dir_or_false(fs, path_spec):
            # ---- DIRECTORY mode (single-path behavior) ----
            var listed = fs.list(path_spec)
            for i in range(len(listed)):
                matched.append(listed[i].copy())
            _sort_and_check_nonempty(matched, path_spec, options, False)
        else:
            # ---- SINGLE-FILE mode ----
            # A non-glob, non-directory path_spec — including one that does NOT
            # EXIST — falls through here (the contract in this
            # method's docstring: "a non-existent file surfaces at open/footer
            # time, not here"). `_is_dir_or_false` MAPS a `path-not-found` raise
            # from `fs.is_dir` to False so the literal path lands in SINGLE-FILE
            # mode rather than propagating the FS-backend probe error out of
            # discovery. This is the discovery-layer policy seam — the FS-backend
            # `is_dir` contract (raises on not-found) is unchanged.
            matched.append(path_spec.copy())
            # No sort / no empty-check: a single literal path is always present.

        var paths = Slab[String].create(max(len(matched), 1))
        for i in range(len(matched)):
            paths.append(matched[i].copy())
        return EagerGlobDiscovery(_paths=paths^)

    @staticmethod
    def open_paths(paths: List[String]) -> EagerGlobDiscovery:
        """Open with an explicit path list (no FS dispatch, no glob, no sort —
        caller order is PRESERVED). Used when the caller already has
        the enumeration (e.g. SDK `read_parquet([p1, p2, p3])`), and as the
        injectable test seam for the glob-filter logic when `fs.list` is a stub
.

        Args:
            paths: Absolute file paths. An empty list yields an empty
                   discovery; callers SHOULD validate non-empty before the
                   factory.

        Returns:
            An `EagerGlobDiscovery` with `_paths` populated from the input
            list, order preserved.
        """
        var capacity = max(len(paths), 1)
        var slab = Slab[String].create(capacity)
        for i in range(len(paths)):
            slab.append(paths[i].copy())
        return EagerGlobDiscovery(_paths=slab^)

    @staticmethod
    def filter_paths(
        var candidates: List[String], pattern: String
    ) raises -> List[String]:
        """Apply the GLOB client-side filter to an EXPLICIT candidate list
        (no FS dispatch). This is the pure mode-logic seam the unit tests exercise
        while `LocalFs.list` is a stub (the e2e path is gated separately):
        `brace_expand(pattern)` -> for each expanded pattern keep candidates
        that `glob_match_path`, dedupe + lexically sort.

        Mirrors the GLOB branch of `open_with_options` exactly (the only
        difference is the candidate source — an injected list vs `fs.list`),
        so a passing `filter_paths` test pins the filtering logic
        independently of FS wiring.

        Args:
            candidates: The candidate path list (as if returned by `fs.list`).
            pattern:    A glob pattern (may contain braces / `**`).

        Returns:
            The deduped, lexically-sorted subset of `candidates` matching
            `pattern`.

        Raises:
            On a >1-`**` glob (via `glob_match_path`).
        """
        var matched = List[String]()
        var patterns = brace_expand(pattern)
        for pi in range(len(patterns)):
            var pat = patterns[pi].copy()
            for ci in range(len(candidates)):
                var cand = candidates[ci].copy()
                if glob_match_path(pat, cand):
                    _append_deduped(matched, cand^)
        sort(matched)
        return matched^

    # -------------------------------------------------------------------------
    # FileDiscovery trait surface
    # -------------------------------------------------------------------------

    @staticmethod
    def is_lazy() -> Bool:
        """Eager: all paths are materialized at `open` time."""
        return False

    @always_inline
    def num_paths(self) -> Int:
        """Number of discovered paths. 1 for single-file mode; N for
        directory-scan / glob / explicit-list mode."""
        return self._paths.len()

    @always_inline
    def path_at(self, idx: Int) raises -> String:
        """The path at `idx` as an owned String. Caller asserts
        `idx < num_paths()` (no bounds check; matches Slab contract)."""
        return self._paths[idx].copy()

    # ---- Partition hooks: EMPTY (EagerGlobDiscovery is not partition-aware) --
    def partition_values_at(self, idx: Int) raises -> PartitionValues:
        """EMPTY — `EagerGlobDiscovery` derives no partition columns. The
        Hive-aware impl is `PrunedHiveDiscovery`."""
        return PartitionValues.empty()

    def partition_schema(self) -> PartitionSchema:
        """EMPTY — `EagerGlobDiscovery` derives no partition schema. The
        Hive-aware impl is `PrunedHiveDiscovery`."""
        return PartitionSchema.empty()

    # ---- typed-partition surface: no-op (no partition columns) ----------
    def num_partition_cols(self) -> Int:
        """0 — `EagerGlobDiscovery` is not partition-aware, so the source
        appends ZERO partition columns (today's behavior, unchanged)."""
        return 0

    def partition_col_type_at(self, idx: Int) -> ArrowType:
        """Unreachable for `EagerGlobDiscovery` (`num_partition_cols()` is 0);
        returns STRING defensively."""
        return ArrowType.STRING

    def partition_col_name_at(self, idx: Int) -> String:
        """Unreachable for `EagerGlobDiscovery` (`num_partition_cols()` is 0);
        returns "" defensively."""
        return String("")


# =============================================================================
# module-private helpers (no UnsafePointer; pure list/string logic).
# =============================================================================


def _append_deduped(mut out: List[String], var candidate: String):
    """Append `candidate` to `out` iff not already present. O(n) per append;
    the matched set is small (a query's file set, not the whole listing). A
    brace-expanded glob can produce overlapping candidate lists across the N
    expanded patterns (e.g. `{a,*}` -> both `a` and `*` match `a`), so the
    union must dedupe."""
    for i in range(len(out)):
        if out[i] == candidate:
            return
    out.append(candidate^)


def _is_dir_or_false[
    FS: FileSystem
](mut fs: FS, path_spec: String) -> Bool:
    """Discovery-layer probe wrapper: `fs.is_dir(path_spec)`, but MAP a raise
    (path-not-found, or any backend probe failure) to `False`.

    The `FileSystem.is_dir` contract is "raises on file-not-found" (see
    `LocalFs.is_dir`). For the auto-detect in `open_with_options`, a path that
    doesn't exist is NOT a directory — it must fall through to SINGLE-FILE mode
    where the literal path surfaces its real error at
    open/footer time. Letting the `is_dir` raise propagate out of discovery
    would turn a plain "read a single file that isn't there" into the wrong
    backend-probe error (e.g. the typed `read_parquet` over a non-existent file,
    which the typed contract expects to fall back to an empty footer schema, not
    raise here). This wrapper keeps the FS-backend `is_dir` contract UNCHANGED
    and confines the "treat a failed dir-probe as not-a-directory" policy to the
    discovery layer."""
    try:
        return fs.is_dir(path_spec)
    except:
        return False


def _sort_and_check_nonempty(
    mut matched: List[String],
    path_spec: String,
    options: GlobDiscoveryOptions,
    is_glob: Bool,
) raises:
    """Lexically sort `matched` and enforce the empty-match policy:
    an empty result RAISES unless `allow_empty_glob` is True."""
    sort(matched)
    if len(matched) == 0 and not options.allow_empty_glob:
        if is_glob:
            raise Error(
                String("EagerGlobDiscovery: no files matched glob pattern '")
                + path_spec
                + "' (set allow_empty_glob=True to permit an empty result)"
            )
        raise Error(
            String("EagerGlobDiscovery: directory '")
            + path_spec
            + "' contains no files (set allow_empty_glob=True to permit an"
            " empty result)"
        )
