# =============================================================================
# JsonSource — concrete SourceLike for JSON / JSONL files on disk.
# =============================================================================
#
# ⚠ ORIENTATION: **ROW**. Orientation is intrinsic to the source FORMAT, and
# JSONL is a row-major on-wire format:
#   1. `EngineContext.read_jsonl_row_streaming` builds this source as a ROW
#      scan, and the typed conformer (`JsonlReader.build_scan_plan`) does the
#      same. Neither passes a `source_kind` — the kind declares it.
#   2. `row_streaming_dispatch._read_row_source_to_row_block` routes
#      `SOURCE_VARIANT_JSON` to `read_jsonl_path_to_row_block`, the JSONL direct
#      ROW reader — the only tag-keyed decode route this arm has.
#   3. `lower_untyped_row_streaming._row_source_path` reads this arm as a
#      SOURCE_KIND_ROW scan's source.
#
# The columnar materializer
# (`komira_json.columnar_materializer.materialize_jsonl_to_batch`) is a direct
# byte-level API; the plan path that uses it decodes and then RE-ROOTS the plan
# at an `InMemorySource`. There is no columnar JSON scan arm.
#
# The orientation is DECLARED once, on the `komira.json` `ScanBinding`
# (`source_variant._json_binding`), and `ScanData.__init__` reads the
# declaration.
#
# Identity: FNV-1a-64 over the path + folded mtime — BYTE-FOR-BYTE the
# `AvroSource` fold. The mtime fold makes the plan-cache invalidate when the
# underlying file is rewritten (stale-cache contract).
#
# ⚠ THE PLAN MUST SEE THAT MTIME. `ScanData.fingerprint()` is not what the
# plan-compile cache keys on — the plan text, via `structural_hash()`, is. So
# the mtime is carried as the `SNAPSHOT_PINNED` token on the scan binding;
# two scans of one JSONL file at different mtimes do not share a plan-compile
# cache key.
#
# `to_dataframe()` is NOT part of the SourceLike trait (cyclic-dep
# avoidance). The ergonomic factories are
# `ctx.read_jsonl_row_streaming(path)` and the typed
# `ctx.read_file(JsonlReader[...](...))`.
# =============================================================================

from std.collections import Optional

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_scan_source.source_like import SourceLike


# =============================================================================
# FNV-1a hash helpers (local copies — source/ keeps its own hash helpers so
# we do not pull collections/ as a dep). Identical to the helpers in
# `parquet_source.mojo` and `column_stats_accum.mojo`.
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


# =============================================================================
# JsonSource
# =============================================================================


struct JsonSource(SourceLike, Movable, Copyable, Deinitable):
    """Concrete SourceLike for a single JSON / JSONL file on disk.

    Identity = FNV-1a-64 over the path string + folded mtime. Same
    (path, mtime) ⇒ same fingerprint (cache hit); file rewritten ⇒
    new mtime ⇒ new fingerprint ⇒ cache miss. Mirrors the ParquetSource
    identity shape (`parquet_source.mojo`).

    Fields:
        path: JSON / JSONL file path on disk.
        schema_cached: caller-supplied schema (JSON has no embedded footer
            schema; the caller MUST pass the column shape they expect to
            materialize. Schema inference can be layered on top via a
            separate call).
        _identity: precomputed FNV-1a-64 hash. Stored so `.fingerprint()`
            is O(1) and stable across `.copy()` and `value^` moves.
        _mtime_ns: file mtime in nanoseconds since unix epoch at ctor.
            Folded into identity (stale-cache invalidation).
            Defaults to 0 — the ctor does NOT stat() the file.
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
        """Primary ctor. The identity hash is computed once here and
        stored so `.fingerprint()` is O(1) and stable across moves /
        clones (the cache-discrimination contract — see the SourceLike
        `fingerprint` docstring in `source_like.mojo`)."""
        # Identity: FNV-1a over the path, then fold the mtime. Two
        # JsonSources over the same (path, mtime) fingerprint identically
        # regardless of construction order; any rewrite changes mtime ⇒
        # fingerprint diverges.
        var h: UInt64 = _fnv1a_offset_basis()
        h = _hash_combine(h, UInt64(path.byte_length()))
        h = _hash_combine(h, _hash_string(path))
        h = _hash_combine(h, mtime_ns)
        self.path = path^
        self.schema_cached = schema^
        self._identity = h
        self._mtime_ns = mtime_ns

    def copy(self) -> Self:
        """Explicit deep clone. Schema is auto-synth Copyable; String,
        UInt64 are trivially copyable. Preserves `_identity` byte-for-
        byte across clones (cache-discrimination contract)."""
        # NOTE: re-using the primary ctor would re-hash the path; we
        # want fingerprint stability across clones, so build a Self
        # directly with the stored `_identity`.
        var out = JsonSource(String(self.path), self.schema_cached.copy(), self._mtime_ns)
        # The primary ctor above already populated `_identity` via the
        # same FNV-1a shape, so the resulting `out._identity` matches
        # `self._identity` by construction. We assert this invariant
        # implicitly (no explicit assignment needed — ctor produced
        # equal hash for equal inputs).
        return out^

    # --- SourceLike trait conformance ---

    def schema(self) -> Schema:
        """Structural schema (eager copy of cached state — no I/O)."""
        return self.schema_cached.copy()

    def estimate_rows(self) -> Int:
        """Row-count estimate: -1 (unknown without a full structural-index
        scan). A future change can wire a fast `\\n`-count heuristic if the
        cardinality estimator demands a non-default."""
        return -1

    def fingerprint(self) -> UInt64:
        """Stable identity = FNV-1a-64 over path + folded mtime.
        Stored field (not recomputed) ⇒ stable across `value^` moves and
        `value.copy()` clones — the cache-discrimination contract."""
        return self._identity

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Return `False` for all predicates — JSON has no equivalent of
        Parquet's row-group zonemap pruning. A predicate over a JsonSource
        stays as a `Filter` node above the scan, applied as a deferred
        OP_FILTER on the materialized RecordBatch.

        Safe degradation per the SourceLike trait default.

        Possible refinement: if a column-stats sketch is computed over
        a JsonSource (mirror of `InMemorySource.get_column_stats`), this
        could return `True` for predicates the stats prove vacuous.
        """
        _ = predicate  # explicitly unused
        return False
