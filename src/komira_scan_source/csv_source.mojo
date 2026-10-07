# =============================================================================
# CsvSource — concrete SourceLike for CSV files on disk.
# =============================================================================
#
# ⚠ ORIENTATION: **ROW**. Orientation is intrinsic to the source FORMAT:
# Parquet is a COLUMN source; CSV is a ROW source.
#   1. `LogicalPlan.scan(path, SOURCE_CSV, ...)` — the factory behind
#      `ctx.read_csv` — threads `kind = SOURCE_KIND_ROW`.
#   2. `lower_untyped_row_streaming._row_source_path` reads the CSV arm as a
#      SOURCE_KIND_ROW scan's source.
#   3. `row_streaming_dispatch._row_source_path_for_dispatch` does the same, and
#      `_read_row_source_to_row_block` routes SOURCE_VARIANT_CSV to the direct
#      CSV row reader.
#
# The orientation is DECLARED once, on the `komira.csv` `ScanBinding`
# (`source_variant._csv_binding`), and `ScanData.__init__` reads the
# declaration.
#
# Identity: FNV-1a-64 over the path + folded mtime + THREE folded dialect terms
# (quote_style_tag, delimiter, has_header). Mirrors the JsonSource +
# ParquetSource fingerprint shape with three extra terms.
#
# ⚠ THE `quote_style_tag` TERM IS LOAD-BEARING. It selects which
# comptime-monomorphized scanner decodes the bytes, so two scans of one path
# under different dialects parse it into DIFFERENT VALUES. The plan text must
# therefore carry it: it is a `ScanBinding` PARAM, and the mtime is the
# SNAPSHOT_PINNED token, so two dialects (or two mtimes) of one CSV file never
# share a plan-compile cache key.
#
# `to_dataframe()` is NOT part of the SourceLike trait (cyclic-dep
# avoidance). The ergonomic factory `ctx.read_csv(path)` lives on
# `EngineContext` and routes through
# `LogicalPlan.scan_from_source(SourceVariant(csv_src))`.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_scan_source.source_like import SourceLike


# =============================================================================
# FNV-1a hash helpers — local copies (matches JsonSource pattern).
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
    """FNV-1a hash_combine: mix two 64-bit hashes via XOR + multiplicative prime."""
    return (a ^ b) * _fnv1a_prime()


# =============================================================================
# Dialect defaults
# =============================================================================
#
# ⚠ DECLARED HERE AND MIRRORED IN `komira_csv.csv_options.CsvReadOptions`, NOT
# imported from it. The core packages cannot depend on `komira_csv` (the chassis
# depends on core, not the reverse), so the two spellings of "the default CSV
# dialect" are structurally separate. A test at the SDK layer, which can
# import both, pins them equal. A core default that drifted from the chassis
# default would mean a plan whose identity describes a dialect the reader is
# not using — self-consistent, and wrong.

comptime CSV_DEFAULT_DELIMITER: UInt8 = UInt8(ord(","))
"""`CsvReadOptions.delimiter`'s default, as a byte."""

comptime CSV_DEFAULT_HAS_HEADER: Bool = True
"""`CsvReadOptions.has_header`'s default."""


# =============================================================================
# CsvSource
# =============================================================================


struct CsvSource(SourceLike, Movable, Copyable, Deinitable):
    """Concrete SourceLike for a single CSV file on disk.

    Identity = FNV-1a-64 over path + folded mtime + the three folded dialect
    terms (quote_style_tag, delimiter, has_header). ORIENTATION IS ROW — see
    the module header.

    Fields:
        path:               CSV file path on disk.
        schema_cached:      inferred schema (populated by the plan compiler
                            after reading the file's header + N sample rows).
                            Defaults to an empty Schema() at construction;
                            the chassis fills it during materialize.
        _identity:          precomputed FNV-1a-64 hash.
        _mtime_ns:          file mtime in nanoseconds since unix epoch.
        quote_style_tag:    runtime tag (0/1/2 == Rfc4180/Excel/Posix)
                            selecting which comptime-monomorphized scanner
                            decodes the bytes (the CSV parallel reader
                            cascades on it at decode time). Defaults to 0
                            (Rfc4180). See `komira_csv.csv_options` for the
                            named constants. This tag is also a
                            `ScanBinding` PARAM, which is what carries it
                            into the plan-compile cache key.
    """

    var path: String
    var schema_cached: Schema
    var _identity: UInt64
    var _mtime_ns: UInt64
    var quote_style_tag: Int
    var delimiter: UInt8
    """The field-separator BYTE. Defaults to `,` (44). Mirrors
    `CsvReadOptions.delimiter`, which is the field the chassis actually reads;
    this is core's copy of the value so it can enter plan identity."""
    var has_header: Bool
    """Whether row 0 is a header line rather than data. Defaults True. Mirrors
    `CsvReadOptions.has_header`."""

    def __init__(
        out self,
        var path: String,
        var schema: Schema,
        mtime_ns: UInt64 = 0,
        quote_style_tag: Int = 0,
        delimiter: UInt8 = CSV_DEFAULT_DELIMITER,
        has_header: Bool = CSV_DEFAULT_HAS_HEADER,
    ):
        """Primary ctor — identity computed once.

        `quote_style_tag`: runtime selector for the QuoteStyle dialect.
        Default 0 == Rfc4180. Pass 1 for Excel, 2 for Posix. The CSV
        parallel reader cascades on this tag at decode time.

        `delimiter` / `has_header`: the other two options that change what the
        BYTES MEAN. See the fold note below for why they are here and not only
        in `CsvReadOptions`.
        """
        var h: UInt64 = _fnv1a_offset_basis()
        h = _hash_combine(h, UInt64(path.byte_length()))
        h = _hash_combine(h, _hash_string(path))
        h = _hash_combine(h, mtime_ns)
        # Fold the quote_style_tag into the identity so that the same path
        # parsed under different dialects produces distinct fingerprints
        # (cache-discrimination: two queries with different dialects must
        # not collide on the result cache).
        h = _hash_combine(h, UInt64(quote_style_tag))
        # `delimiter` and `has_header` are the remaining two options that
        # change what the bytes MEAN, so they are folded too: schema
        # inference reads both, so `read_csv('f', delim='|')` and
        # `read_csv('f')` produce two DIFFERENT schemas and must not share a
        # plan-compile cache key. `has_header=false` is the sharper of the
        # two: it does not merely retype a column, it decides whether row 0
        # is DATA, so a cache hit across it would return a different ROW
        # COUNT.
        h = _hash_combine(h, UInt64(delimiter))
        h = _hash_combine(h, UInt64(1) if has_header else UInt64(0))
        self.path = path^
        self.schema_cached = schema^
        self._identity = h
        self._mtime_ns = mtime_ns
        self.quote_style_tag = quote_style_tag
        self.delimiter = delimiter
        self.has_header = has_header

    def copy(self) -> Self:
        """Explicit deep clone — preserves _identity byte-for-byte."""
        var out = CsvSource(
            String(self.path),
            self.schema_cached.copy(),
            self._mtime_ns,
            self.quote_style_tag,
            self.delimiter,
            self.has_header,
        )
        return out^

    # --- SourceLike trait conformance ---

    def schema(self) -> Schema:
        """Structural schema. For a freshly-constructed CsvSource the
        cached schema is empty — the chassis fills it during scan."""
        return self.schema_cached.copy()

    def estimate_rows(self) -> Int:
        """-1 = unknown without a full file scan."""
        return -1

    def fingerprint(self) -> UInt64:
        return self._identity

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Return `False` for all predicates — CSV has no equivalent of
        Parquet's row-group zonemap pruning. A predicate over a CsvSource
        stays as a Filter node above the scan."""
        _ = predicate
        return False
