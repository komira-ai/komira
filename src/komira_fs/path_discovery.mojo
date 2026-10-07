# =============================================================================
# komira_fs.path_discovery — PathDiscovery
# =============================================================================
#
#
# Concrete file-path discovery. FS-aware (issues `is_dir` + `list` via the
# FS generic at `list_files`/`open` time), format-agnostic (does NOT open
# files, parse footers, or know about parquet / any other format).
#
# Knows ONLY about paths. The factory + reader stack (`ReaderFactory` +
# per-format `Reader`) is what turns these paths into format-specific
# Reader instances at construction time.
#
# Single concrete struct (NOT a trait) for v0.1. Both single-file and
# directory-scan modes auto-detect at construction and converge to the
# same internal `Slab[String]` representation. v0.2+ may promote to a
# trait when paginated S3-list semantics need different shape — at that
# time, `MultiConsumerSource[FS, RF, expr_o, filter_o]` grows ONE
# type-param to become `MultiConsumerSource[FS, DISC, RF, expr_o,
# filter_o]` (one-line signature change).
#
# Why concrete struct, not trait, for v0.1: spec
# What it does NOT do: spec
# Pointer discipline:
#   * No UnsafePointer in any method signature.
#   * No wildcard origins (the struct is destroy-recreatable through
#     EngineContext via the parquet_source it composes into; destroy-recreate
#     hazard avoided by sticking to typed values).
# =============================================================================

from komira_fs.file_system import FileSystem
from komira_collections.slab import Slab


@fieldwise_init
struct PathDiscovery(Movable, Deinitable):
    """Concrete file-path discovery (FS-aware, format-agnostic).

    Field set:
      var _paths: Slab[String]
        Owned path strings. Length-1 in single-file mode is fine; the
        slab's empty-state contract is unchanged from how `Slab[T]`
        is used elsewhere. Reuses Slab for consistency with the
        source's `_readers: Slab[Reader]` slab.
    """

    var _paths: Slab[String]

    @staticmethod
    def open[FS: FileSystem](
        mut fs: FS, path_spec: String,
    ) raises -> PathDiscovery:
        """Auto-detect single-file vs directory-scan mode. Calls
        `fs.is_dir(path_spec)`; if True, populates `_paths` from
        `fs.list(path_spec)`; if False, populates `_paths` with a
        single-element slab containing `path_spec` itself.

        v0.1 enumeration is eager + ordered (stable, alphanumeric for
        directory-scan via `fs.list`'s contract). v0.2+ may add a
        streaming variant that produces paths incrementally.

        Args:
            fs:        FileSystem-conformer instance. Mutable receiver
                       per `FileSystem.open`'s mutability contract;
                       `is_dir` + `list` are sync and may share fd
                       state with future opens.
            path_spec: Either an absolute file path or a directory
                       prefix.

        Returns:
            A PathDiscovery with `_paths` populated.

        Raises:
            On I/O failure of `is_dir` or `list`.
        """
        var paths = Slab[String].create(8)
        if fs.is_dir(path_spec):
            var listed = fs.list(path_spec)
            var i = 0
            while i < len(listed):
                paths.append(listed[i].copy())
                i = i + 1
        else:
            paths.append(path_spec.copy())
        return PathDiscovery(_paths=paths^)

    @staticmethod
    def open_paths(paths: List[String]) -> PathDiscovery:
        """Open with an explicit path list (no FS dispatch). Used when
        the caller already has the path enumeration in hand (e.g. SDK
        `read_parquet([p1, p2, p3])`). See spec

        Args:
            paths: List of absolute file paths. Empty list produces an
                   empty discovery; callers SHOULD validate non-empty
                   before invoking the factory.

        Returns:
            A PathDiscovery with `_paths` populated from the input list.
        """
        var capacity = max(len(paths), 1)
        var slab = Slab[String].create(capacity)
        var i = 0
        while i < len(paths):
            slab.append(paths[i].copy())
            i = i + 1
        return PathDiscovery(_paths=slab^)

    @always_inline
    def num_paths(self) -> Int:
        """Number of discovered paths. 1 for single-file mode; N for
        directory-scan or explicit-list mode."""
        return self._paths.len()

    @always_inline
    def path_at(self, idx: Int) -> String:
        """Returns the path at `idx` as an owned String. Caller asserts
        `idx < num_paths()` (no bounds check; matches Slab contract)."""
        return self._paths[idx].copy()

    def list_files[FS: FileSystem](
        self, fs: FS, path_spec: String,
    ) raises -> List[String]:
        """Re-enumerate the path list against `fs` + `path_spec`. Used
        when the caller wants a fresh listing (e.g. a dynamic refresh
        path that v0.2+ may add). v0.1 callers use the immutable
        `_paths` slab via `num_paths` / `path_at`.

        Generic METHOD parameter `FS: FileSystem` — NOT a struct param,
        so the `MultiConsumerSource[FS, RF, expr_o, filter_o]`
        signature stays at 4 type params per spec
        """
        var out = List[String]()
        if fs.is_dir(path_spec):
            var listed = fs.list(path_spec)
            var i = 0
            while i < len(listed):
                out.append(listed[i].copy())
                i = i + 1
        else:
            out.append(path_spec.copy())
        return out^
