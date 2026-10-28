# =============================================================================
# SerdeFormat — trait for on-disk record-shape format markers
# =============================================================================
#
# `SerdeFormat` is a TYPE-SYSTEM marker trait. One conformer per concrete file
# format. The trait is deliberately minimal: it carries only an associated
# `Options` type, a `name()` for diagnostics, a `detect_extension(path)` for
# auto-detection by `file_sink(path)` / `file_source(path)`, and a
# `default_options()` static factory (required because the `Options` trait
# bound does NOT include `Defaultable`, so a parametric ctor cannot call
# `Self.F.Options()` directly).
#
# Conformers:
#   - `Parquet[C: Compression = Snappy]`  (per-page-compressed columnar)
#   - `Jsonl`                              (record-stream, uncompressed)
#   - `Csv`                                (record-stream, uncompressed)
#   - `Arrow`                              (Arrow IPC stream)
#   - `WholeFileCompressed[Inner, C]`      (whole-file codec wrapper for
#                                           record-stream formats only)
#
# All conformers live in `arrow/formats.mojo`. The accompanying
# Options structs (ParquetOptions / JsonOptions / CsvOptions / ArrowOptions)
# live in `arrow/serde_format_options.mojo`.
#
# DISTINCT from the async filesystem layer's `FileFormat` (a read-side I/O
# umbrella with capability flags + 3-layer sub-traits); the names differ
# deliberately.
#
# Dispatch into format-specific code happens via `(F == X)`
# cascades inside `LocalFormatSink[F: SerdeFormat]` / `FileSource[F]` bodies.
# The trait body itself is intentionally minimal — no write_batch /
# read_batch on the trait, because the write path needs mutable state which
# would collide with the marker-struct shape (we want each marker to be a
# zero-byte struct that lives at the type system level only).
#
# Validated shapes:
#   - `comptime Options:` associated comptime type with trait bound.
#   - `@staticmethod fn` on a trait.
#   - `(F == X)` cascade in FileSink body (JIT and AOT).
# =============================================================================


# =============================================================================
# CompressionModel — discriminator for format ↔ compression composition
# =============================================================================
#
# Factory dispatch (`read(path)` auto-detect, `file_sink(path)` auto-detect,
# the `df.write_to_parquet(...)` vs `df.write_to_jsonl_gz(...)` branch) needs to know at COMPILE TIME whether a given `F: SerdeFormat`
# requires its compression to be PART OF THE FORMAT (Parquet — codec lives
# in footer + per-page header), or whether compression must be supplied
# EXTERNALLY via `WholeFileCompressed[F, C]` (Jsonl / Csv — no internal
# codec slot), or whether the format has BOTH options (Arrow IPC — body-
# stream compression OR whole-file wrap).
#
# Modeling this with a comptime enum makes the factory dispatch a
# `comptime if F.COMPRESSION_MODEL == CompressionModel.InternalRequired:`
# cascade — zero runtime cost, clear compile errors when callers compose
# `WholeFileCompressed[Parquet[C], Gzip]` (illegal: Parquet already owns
# its codec; double-wrap is nonsense).
# =============================================================================


struct CompressionModel(
    Copyable, Movable, ImplicitlyCopyable, Equatable
):
    """How a `SerdeFormat` composes with `Compression`.

    Three positions in the type tree:
      - `InternalRequired`: the format OWNS its codec; passing it through
        `WholeFileCompressed[..., C]` is ILLEGAL. Per-page Parquet is the
        canonical case: `Parquet[C]` already binds `C` and the on-disk
        footer carries `C.PARQUET_CODEC_ID`. Factory dispatch: the codec is
        comptime-fixed in `F` itself.
      - `ExternalOnly`: the format has NO internal codec slot. Compression
        is ONLY available via `WholeFileCompressed[F, C]` wrap. Canonical:
        `Jsonl` / `Csv` (record-stream formats with no built-in compression).
      - `InternalOptional`: the format MAY carry internal compression OR
        be whole-file-wrapped. Canonical: `Arrow` (Arrow IPC supports
        body-stream compression in the spec; per-buffer compression uses the
        typed `Arrow[C]` parametric form, and whole-file wrapping uses
        `WholeFileCompressed[Arrow, C]`).

    Encoded as `Int8` for cheap comptime-equality via `_type_is_eq` is
    NOT viable (different `F.COMPRESSION_MODEL` values are RUNTIME-equal,
    not type-distinct); `Equatable` lets factory bodies use `comptime if
    F.COMPRESSION_MODEL == CompressionModel.InternalRequired:` directly.
    """

    var value: Int8

    comptime InternalRequired = CompressionModel(0)
    comptime ExternalOnly = CompressionModel(1)
    comptime InternalOptional = CompressionModel(2)

    def __init__(out self, value: Int8):
        self.value = value

    @always_inline
    def __eq__(self, other: CompressionModel) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: CompressionModel) -> Bool:
        return self.value != other.value


# =============================================================================


trait SerdeFormat(Movable, Deinitable):
    """Format-contract trait for serde-shape on-disk file formats.

    Conformers:
      - `Parquet[C: Compression = Snappy]` (parquet via komira_parquet)
      - `Jsonl` (ndjson / array via the JSON reader)
      - `Csv` (RFC-4180-ish via komira_parquet.csv_reader / csv_emit)
      - `Arrow` (Arrow IPC stream)
      - `WholeFileCompressed[Inner, C]` (whole-file codec wrapper)

    Each conformer owns:
      - An `Options` associated type with trait bound
        `Movable & Copyable & ImplicitlyCopyable`. Per-format knobs live
        on this struct; the trait surface stays minimal.
      - `COMPRESSION_MODEL: CompressionModel` — compile-time discriminator:
        does this
        format OWN its codec (`InternalRequired`, e.g. Parquet), require
        external wrapping (`ExternalOnly`, e.g. Jsonl/Csv), or support
        both (`InternalOptional`, e.g. Arrow IPC)? Factory dispatch reads
        this in a `comptime if` cascade to choose the
        right read/write path AND to reject illegal compositions like
        `WholeFileCompressed[Parquet[Snappy], Gzip]` at compile time.
      - `name()` — staticmethod; short human-readable name for EXPLAIN
        output, error messages, telemetry (e.g. "parquet", "jsonl", "csv").
      - `detect_extension(path)` — staticmethod; True iff `path` is
        recognized as this format. Used by `file_sink(path)` /
        `file_source(path)` auto-detect.
      - `default_options()` — staticmethod; constructs a default-valued
        `Options`. Needed because the trait bound on `Options` does NOT
        include `Defaultable`, so a parametric ctor `fn __init__(out self,
        var path: String, var options: F.Options = F.default_options())`
        cannot use `Self.F.Options()` (zero-arg ctor) directly.

    The super-clause is `(Movable, Deinitable)` — matches the
    async filesystem layer's `FileFormat` super for consistency.
    `Copyable` is NOT required on the trait; the concrete marker structs
    declare it themselves because they are zero-byte structs (Copyable
    is trivial).
    """

    comptime Options: Movable & Copyable & ImplicitlyCopyable & Deinitable
    comptime COMPRESSION_MODEL: CompressionModel

    @staticmethod
    def name() -> StaticString:
        ...

    @staticmethod
    def detect_extension(path: String) -> Bool:
        ...

    @staticmethod
    def default_options() -> Self.Options:
        ...
