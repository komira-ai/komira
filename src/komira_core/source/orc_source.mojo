# =============================================================================
# OrcSource — concrete SourceLike for Apache ORC files on disk.
# =============================================================================
#
# `ctx.read_orc` decodes a whole file straight into a RecordBatch and
# bypasses `SourceVariant`. This source is the substrate arm so an ORC file
# can flow through the canonical
# `LogicalPlan.scan_from_source(SourceVariant(...))` path, letting
# stripe-parallel decode and the `read_orc_bytes_projected` column-pushdown
# plumbing compose with the engine's morsel driver.
#
# Architectural decision: OrcSource is `SOURCE_KIND_COLUMNAR` — the ORC
# decoder materializes the entire file (across stripes) into a single
# RecordBatch at materialize-time (mirrors AvroSource / JsonSource /
# CsvSource). Per-stripe streaming morsels are a possible refinement.
#
# Identity: FNV-1a-64 over the path + folded mtime + folded projection
# fingerprint. Mirrors JsonSource / CsvSource / ParquetSource fingerprint
# shapes. Projection is folded into identity so the same path with different
# column-projections produces distinct fingerprints (cache-discrimination
# contract — two queries reading different subsets of the same file must
# not collide on the result cache).
#
# `to_dataframe()` is NOT part of the SourceLike trait (cyclic-dep
# avoidance). The ergonomic factory `ctx.read_orc(path)` lives on
# `EngineContext` and uses the direct path; an opt-in
# `ctx.read_orc_lazy(path)` on top of this struct routes through
# `LogicalPlan.scan_from_source`.
#
# Encapsulation: no `UnsafePointer` in any public sig. Movable+Copyable +
# Deinitable per SourceLike trait bound. Projection is a
# `List[Int]` of OUTPUT column indices (into the top-level struct's direct
# children, matching `read_orc_bytes_projected` semantics in `komira_orc`).
# =============================================================================

from komira_core.arrow.schema import Schema
from komira_core.plan.expr import Expr
from komira_core.source.source_like import SourceLike


# =============================================================================
# FNV-1a hash helpers — local copy (mirrors JsonSource / CsvSource).
# =============================================================================


@always_inline
def _orc_source_fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _orc_source_fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def _orc_source_hash_string(s: String) -> UInt64:
    """FNV-1a 64-bit hash over a String's bytes. Walks via `as_bytes()`
    (no UnsafePointer in the public surface)."""
    var h: UInt64 = _orc_source_fnv1a_offset_basis()
    var prime: UInt64 = _orc_source_fnv1a_prime()
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = h ^ UInt64(b[i])
        h = h * prime
    return h


def _orc_source_hash_combine(a: UInt64, b: UInt64) -> UInt64:
    """FNV-1a hash_combine: order-sensitive 64-bit hash combine."""
    return (a ^ b) * _orc_source_fnv1a_prime()


def _orc_source_hash_projection(projection: List[Int]) -> UInt64:
    """Fold a projection vector into a single 64-bit fingerprint chunk.
    Empty projection (= "all columns") hashes to a stable zero-payload
    sentinel; non-empty projections fold each index in order (order-sensitive
    to match `read_orc_bytes_projected`'s output-column ordering contract).
    """
    var h: UInt64 = _orc_source_fnv1a_offset_basis()
    h = _orc_source_hash_combine(h, UInt64(len(projection)))
    for i in range(len(projection)):
        h = _orc_source_hash_combine(h, UInt64(projection[i]))
    return h


# =============================================================================
# OrcSource
# =============================================================================


struct OrcSource(SourceLike, Movable, Copyable, Deinitable):
    """Concrete SourceLike for a single Apache ORC file on disk.

    Identity = FNV-1a-64 over path + folded mtime + folded projection
    (mirrors JsonSource / CsvSource fingerprint shape; projection is
    order-sensitive).

    Fields:
        path:               ORC file path on disk.
        schema_cached:      caller-supplied / lazily-populated schema. ORC
                            files DO carry an embedded footer schema (see
                            `komira_orc.orc_schema.OrcSchema`); this field
                            starts empty + the decoder reads the footer at
                            materialize-time (mirrors `CsvSource`, where the
                            chassis fills the schema on scan).
        projection:         OUTPUT column indices into the root struct's
                            DIRECT children, in caller order. Empty means
                            "all columns". Matches the semantics of
                            `read_orc_bytes_projected` in `komira_orc`.
                            Folded into `_identity`.
        _identity:          precomputed FNV-1a-64 hash. Stable across
                            `.copy()` / `value^` moves (cache-discrimination
                            contract).
        _mtime_ns:          file mtime in nanoseconds since unix epoch.
                            Folded into identity (stale-cache
                            invalidation). Defaults to 0 — the ctor does
                            NOT stat() the file.
    """

    var path: String
    var schema_cached: Schema
    var projection: List[Int]
    var _identity: UInt64
    var _mtime_ns: UInt64

    def __init__(
        out self,
        var path: String,
        var schema: Schema,
        var projection: List[Int],
        mtime_ns: UInt64 = 0,
    ):
        """Primary ctor — identity computed once, stable across moves/clones."""
        var h: UInt64 = _orc_source_fnv1a_offset_basis()
        h = _orc_source_hash_combine(h, UInt64(path.byte_length()))
        h = _orc_source_hash_combine(h, _orc_source_hash_string(path))
        h = _orc_source_hash_combine(h, mtime_ns)
        h = _orc_source_hash_combine(h, _orc_source_hash_projection(projection))
        self.path = path^
        self.schema_cached = schema^
        self.projection = projection^
        self._identity = h
        self._mtime_ns = mtime_ns

    @staticmethod
    def from_path(var path: String) raises -> OrcSource:
        """Convenience ctor — empty schema (chassis fills at scan time), no
        projection (all columns)."""
        return OrcSource(
            path^,
            Schema(),
            List[Int](),
            UInt64(0),
        )

    def copy(self) -> Self:
        """Explicit deep clone — preserves _identity byte-for-byte across
        clones (the cache-discrimination contract). Mirrors JsonSource.copy."""
        var proj_copy = List[Int]()
        for i in range(len(self.projection)):
            proj_copy.append(self.projection[i])
        var out = OrcSource(
            String(self.path),
            self.schema_cached.copy(),
            proj_copy^,
            self._mtime_ns,
        )
        return out^

    # --- SourceLike trait conformance ---

    def schema(self) -> Schema:
        """Structural schema (eager copy of cached state — no I/O). For a
        freshly-constructed OrcSource the cached schema is empty; the
        decoder fills it during materialize from the file's Footer."""
        return self.schema_cached.copy()

    def estimate_rows(self) -> Int:
        """-1 = unknown without reading the footer. A future change can lift
        this to the actual Footer.numberOfRows once the per-source
        `tail.footer.num_rows` cache is threaded through here (mirrors
        ParquetSource's footer-cache pattern)."""
        return -1

    def fingerprint(self) -> UInt64:
        """Stable identity = FNV-1a-64 over path + folded mtime + folded
        projection. Stable across `value^` moves and `value.copy()` clones —
        the cache-discrimination contract."""
        return self._identity

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Return `False` for all predicates — the ORC reader has
        column-projection pushdown (handled via `projection: List[Int]`) and
        stripe-stats pruning (handled inside the reader via
        `read_orc_bytes_pruned` / `read_orc_bytes_filtered` in `komira_orc`),
        but the SourceLike pushdown contract is about FILTER expressions
        flowing into the scan node. ORC's stride-stats / bloom-filter
        pushdown happens inside the chassis at decode time and is not
        surfaced via SourceLike.

        Returning False keeps the predicate as a `Filter` node above the
        scan; correctness is preserved (the chassis still consults stride
        stats internally — that path is independent of SourceLike). The
        only thing returning True would buy is a tag-handoff into
        ScanData.filter, which the engine does not consume for ORC.
        """
        _ = predicate
        return False
