# =============================================================================
# AvroSource — concrete SourceLike for Apache Avro OCF files on disk.
# =============================================================================
#
# The leaf of an Avro file in a plan. Avro OCF is ROW-oriented on disk, and
# the `komira.avro` binding declares `orientation = ROW`. `read_avro('path')`
# in SQL builds this source (`sql_tvf_bind._avro_tvf_scan`) with the schema
# the file's OCF header gives, and lowering cuts the scan into a SOURCE_AVRO
# segment (`lowering.cut_scan_avro`), whose source decodes the file with the
# OCF reader (`pipeline_exec.source_avro`). `AvroReader.build_scan_plan`
# (`op_typed_source_api`) builds the same leaf.
#
# Mirrors `JsonSource` (the closest sibling — a single path + caller-supplied
# schema, no projection). Identity = FNV-1a-64 over the path + folded mtime
# (same shape as JsonSource / CsvSource / ParquetSource), so the plan-cache
# invalidates when the underlying file is rewritten (stale-cache contract).
#
# `to_dataframe()` is NOT part of the SourceLike trait (cyclic-dep
# avoidance).
#
# Encapsulation: no `UnsafePointer` in any public sig. Movable+Copyable +
# Deinitable per SourceLike trait bound.
# =============================================================================

from arrow.schema import Schema
from plan_expr.expr import Expr
from scan_source.source_like import SourceLike


# =============================================================================
# FNV-1a hash helpers — local copy (mirrors JsonSource / OrcSource / CsvSource).
# =============================================================================


@always_inline
def _avro_source_fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _avro_source_fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def _avro_source_hash_string(s: String) -> UInt64:
    """FNV-1a 64-bit hash over a String's bytes. Walks via `as_bytes()`
    (no UnsafePointer in the public surface)."""
    var h: UInt64 = _avro_source_fnv1a_offset_basis()
    var prime: UInt64 = _avro_source_fnv1a_prime()
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = h ^ UInt64(b[i])
        h = h * prime
    return h


def _avro_source_hash_combine(a: UInt64, b: UInt64) -> UInt64:
    """FNV-1a hash_combine: order-sensitive 64-bit hash combine."""
    return (a ^ b) * _avro_source_fnv1a_prime()


# =============================================================================
# AvroSource
# =============================================================================


struct AvroSource(SourceLike, Movable, Copyable, Deinitable):
    """Concrete SourceLike for a single Apache Avro OCF file on disk.

    Identity = FNV-1a-64 over the path string + folded mtime. Same
    (path, mtime) => same fingerprint (cache hit); file rewritten => new mtime
    => new fingerprint => cache miss. Mirrors the JsonSource identity shape.

    Fields:
        path: Avro OCF file path on disk.
        schema_cached: the Arrow schema derived from the OCF header's embedded
            Avro schema (identity resolution). `read_avro`'s binder
            (`sql_tvf_bind.avro_tvf_schema`) parses the OCF header schema up
            front and passes it here, so the scan leaf's output schema is the
            file's.
        _identity: precomputed FNV-1a-64 hash. Stored so `.fingerprint()` is
            O(1) and stable across `.copy()` and `value^` moves.
        _mtime_ns: file mtime in nanoseconds since unix epoch at ctor. Folded
            into identity (stale-cache invalidation). Defaults to 0 — the
            ctor does NOT stat() the file.
    """

    var path: String
    var schema_cached: Schema
    var _identity: UInt64
    var _mtime_ns: UInt64

    def __init__(
        out self,
        var path: String,
        var schema: Schema,
        mtime_ns: UInt64 = 0,
    ):
        """Primary ctor. The identity hash is computed once here and stored so
        `.fingerprint()` is O(1) and stable across moves / clones (the
        cache-discrimination contract). Mirrors JsonSource.__init__."""
        var h: UInt64 = _avro_source_fnv1a_offset_basis()
        h = _avro_source_hash_combine(h, UInt64(path.byte_length()))
        h = _avro_source_hash_combine(h, _avro_source_hash_string(path))
        h = _avro_source_hash_combine(h, mtime_ns)
        self.path = path^
        self.schema_cached = schema^
        self._identity = h
        self._mtime_ns = mtime_ns

    def copy(self) -> Self:
        """Explicit deep clone — preserves _identity byte-for-byte across
        clones (the cache-discrimination contract). Mirrors JsonSource.copy."""
        var out = AvroSource(
            String(self.path), self.schema_cached.copy(), self._mtime_ns
        )
        return out^

    # --- SourceLike trait conformance ---

    def schema(self) -> Schema:
        """Structural schema (eager copy of cached state — no I/O)."""
        return self.schema_cached.copy()

    def estimate_rows(self) -> Int:
        """Row-count estimate: -1 (unknown without a full block scan). A future
        change can wire a fast block-object-count sum if the cardinality
        estimator demands a non-default."""
        return -1

    def fingerprint(self) -> UInt64:
        """Stable identity = FNV-1a-64 over path + folded mtime. Stored field
        (not recomputed) => stable across `value^` moves and `value.copy()`
        clones — the cache-discrimination contract."""
        return self._identity

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Return `False` for all predicates — Avro has no equivalent of
        Parquet's row-group zonemap pruning. A predicate over an AvroSource
        stays as a `Filter` node above the scan, which lowering cuts into an
        operator of the SOURCE_AVRO segment. Safe degradation per SourceLike
        trait default."""
        _ = predicate
        return False
