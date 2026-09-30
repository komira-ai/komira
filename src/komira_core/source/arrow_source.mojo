# =============================================================================
# ArrowSource — concrete SourceLike for Arrow IPC files on disk.
# =============================================================================
#
# The struct shape mirrors `ParquetSource`: it carries the path, the
# cached schema, the file mtime and a row-count hint. The Arrow IPC
# decode body (Schema-fbs + Message-fbs parser + per-DType decoder
# family, and per-buffer codec dispatch on `BodyCompression.codec` →
# Lz4Frame / Zstd) lives in the Arrow IPC reader.
#
# Per-codec dispatch happens INSIDE the decoder at decode time (the
# `BodyCompression` flatbuf field is in each RecordBatch message;
# the same struct handles all 3 codec arms — same pattern as
# `ParquetSource` handles 4 Parquet codec arms via runtime
# dispatch over `ColumnMetaData.codec`).
#
# Encapsulation: no `UnsafePointer` in any public sig. Movable+Copyable
# + Deinitable per SourceLike trait bound.
# =============================================================================

from komira_core.arrow.schema import Schema
from komira_core.plan.expr import Expr
from komira_core.source.source_like import SourceLike


# =============================================================================
# FNV-1a hash helpers — local copy (avoids pulling komira_core.collections
# as a dep; matches the pattern in parquet_source.mojo).
# =============================================================================


@always_inline
def _arrow_source_fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _arrow_source_fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def _arrow_source_hash_string(s: String) -> UInt64:
    """FNV-1a 64-bit hash over a String's bytes."""
    var h: UInt64 = _arrow_source_fnv1a_offset_basis()
    var prime: UInt64 = _arrow_source_fnv1a_prime()
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        h = h ^ UInt64(b[i])
        h = h * prime
    return h


def _arrow_source_hash_combine(a: UInt64, b: UInt64) -> UInt64:
    """FNV-1a hash_combine: order-sensitive 64-bit hash combine."""
    return (a ^ b) * _arrow_source_fnv1a_prime()


# =============================================================================
# ArrowSource — Arrow IPC file source
# =============================================================================


struct ArrowSource(SourceLike, Movable, Copyable, Deinitable):
    """Arrow IPC Stream/File format source.

    The SourceLike trait methods return schema/estimate_rows/fingerprint
    from cached state (mirrors ParquetSource pre-footer-read). Schema is
    read once from the file's first Message (Schema-fbs message);
    row-count is the sum of RecordBatch.length fields across all
    RecordBatch messages (cached after first full scan).

    Per-buffer codec dispatch reads `BodyCompression.codec` from each
    RecordBatch message (Uncompressed = no field; LZ4_FRAME = 0;
    ZSTD = 1) at decode time; the SourceVariant arm choice
    (tag 7 / 8 / 9) is documentary — the runtime codec is what the
    Arrow IPC message says, mirroring ParquetSource behavior with
    parquet codecs.

    Fingerprint: FNV-1a over `path` + folded mtime (same shape as
    ParquetSource's stale-cache invalidation contract).
    """

    var path: String
    var _schema_cached: Schema
    var _mtime_ns: UInt64
    var _estimated_rows: Int

    def __init__(
        out self,
        var path: String,
        var schema: Schema,
        mtime_ns: UInt64 = 0,
        estimated_rows: Int = -1,
    ):
        """Construct an ArrowSource. The caller supplies the parsed
        Schema (see `arrow_source_from_path`).

        Args:
            path: File path. Consumed.
            schema: Arrow data schema (parsed from the IPC Stream's
                first Schema message). Consumed.
            mtime_ns: File modification time in ns since unix epoch
                (folded into fingerprint for stale-cache
                invalidation). 0 = unknown.
            estimated_rows: Row count if known (sum of RecordBatch
                lengths after a full scan); -1 = unknown.
        """
        self.path = path^
        self._schema_cached = schema^
        self._mtime_ns = mtime_ns
        self._estimated_rows = estimated_rows

    def copy(self) -> Self:
        """Deep-clone. Schema is owned by-value so a structural copy
        suffices; path/mtime are POD."""
        return ArrowSource(
            String(self.path),
            self._schema_cached.copy(),
            mtime_ns=self._mtime_ns,
            estimated_rows=self._estimated_rows,
        )

    # =========================================================================
    # SourceLike trait conformance
    # =========================================================================

    def schema(self) -> Schema:
        """Return a copy of the cached schema."""
        return self._schema_cached.copy()

    def estimate_rows(self) -> Int:
        """Row-count hint. -1 = unknown (until a full-scan row counter
        fills it)."""
        return self._estimated_rows

    def fingerprint(self) -> UInt64:
        """Stable identity hash. Folds path + mtime (stale-cache
        invalidation contract)."""
        var h = _arrow_source_hash_string(self.path)
        h = _arrow_source_hash_combine(h, self._mtime_ns)
        return h

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Per-predicate pushdown query.

        Returns False — Arrow IPC has no decode-time pruning (no
        zonemap / dictionary-filter equivalent on the format level).
        Limited pushdown for partition-style path-pattern filters
        (similar to ParquetSource's Hive partition support) is possible,
        but the canonical Arrow IPC scan reads full batches.
        """
        return False


# =============================================================================
# arrow_source_from_path — path-mode factory.
# =============================================================================
#
# A path-mode entry opens the Arrow IPC file, validates the ARROW1 magic,
# decodes the Footer's re-emitted Schema, and caches it on the returned
# ArrowSource.
#
# Routing layered above this helper:
#   - `ctx.read_arrow(path)`  — eager (decodes all bytes; returns DataFrame
#     via `DataFrame.from_record_batch`).
#   - `arrow_source_from_path(path)` — lazy (returns an ArrowSource
#     carrying the cached Schema; the RecordBatch decode happens in the
#     engine scan).
#
# This helper does NOT live as a `@staticmethod` on ArrowSource because
# the file reader lives in the SDK layer, which depends on
# `komira_core.arrow` — making it a method on a komira_core type would
# force the import cycle to invert. The SDK's source factories are the
# public surface; this module provides the typed-cache field-layout entry
# point and the trait-conformant struct.


def arrow_source_from_schema(
    var path: String, var schema: Schema, mtime_ns: UInt64 = 0,
    estimated_rows: Int = -1,
) -> ArrowSource:
    """Free-function ergonomic factory mirroring the in-tree pattern
    used by `parquet_source` helpers — constructs an ArrowSource with a
    pre-parsed Schema (the typed cache shape the SourceVariant arms
    consume).

    SDK source factories use this after extracting the Schema from the
    file's Footer via the Arrow IPC file reader. The trait conformance
    lives on the ArrowSource struct above; this helper exists so callers
    can construct without typing the keyword form.
    """
    return ArrowSource(
        path^,
        schema^,
        mtime_ns=mtime_ns,
        estimated_rows=estimated_rows,
    )
