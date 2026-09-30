# =============================================================================
# AvroSource — concrete SourceLike for Apache Avro OCF files on disk.
# =============================================================================
#
# Avro row-native READ. Avro OCF is ROW-oriented on disk; the row-native
# reader (`avro_rowblock_reader.read_avro_path_to_row_block`) decodes each
# OCF record's fields DIRECTLY into a RowBlock via the same `AvroByteReader`
# varint/union/string primitives the column path's `ActionTableInterpreter`
# uses — NOT the col->row shortcut orc/arrow use. This source is the substrate
# arm so an Avro file can flow through the canonical
# `LogicalPlan.scan_from_source(SourceVariant(...), source_kind=ROW)` path that
# the row-streaming segment dispatch serves.
#
# Mirrors `JsonSource` (the closest sibling — a single path + caller-supplied
# schema, no projection). Identity = FNV-1a-64 over the path + folded mtime
# (same shape as JsonSource / CsvSource / ParquetSource), so the plan-cache
# invalidates when the underlying file is rewritten (stale-cache contract).
#
# Architectural note: UNLIKE JsonSource/OrcSource (which are SOURCE_KIND_COLUMNAR
# — their decoders emit Arrow batches directly), AvroSource is constructed with
# an EXPLICIT `source_kind == SOURCE_KIND_ROW` by `ctx.read_avro_row_streaming`
# so the genuine row-native producer fires. The column path (`ctx.read_avro`)
# does NOT use this source — it routes through the eager `read_avro_bytes_parallel`
# direct path into an InMemorySource (mirroring `read_json`).
#
# `to_dataframe()` is NOT part of the SourceLike trait (cyclic-dep
# avoidance). The ergonomic factory `ctx.read_avro_row_streaming(path)`
# lives on `EngineContext` and roots the plan at a SOURCE_KIND_ROW scan
# over this source.
#
# Encapsulation: no `UnsafePointer` in any public sig. Movable+Copyable +
# Deinitable per SourceLike trait bound.
# =============================================================================

from komira_core.arrow.schema import Schema
from komira_core.plan.expr import Expr
from komira_core.source.source_like import SourceLike


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
            Avro schema (identity resolution). `ctx.read_avro_row_streaming`
            parses the OCF header schema up front and passes it here so the
            scan leaf's output schema (the RowBlock layout) is authoritative.
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
        stays as a `Filter` node above the scan, applied row-native by the
        RowStreamingSegment. Safe degradation per SourceLike trait default."""
        _ = predicate
        return False
