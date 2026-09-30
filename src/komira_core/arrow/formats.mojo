# =============================================================================
# Concrete format markers — conformers of `SerdeFormat`
# =============================================================================
#
# Format markers are ZERO-BYTE structs (the `_reserved: Bool` field is a
# @fieldwise_init placeholder; padded away in practice) that live at the
# type-system level only. They carry no runtime state — their job is to
# parameterize `LocalFormatSink[F]` / `FileSource[F]` so the per-format dispatch
# in the sink/source body can specialize via `(F == X)`.
#
# Five markers:
#   - `Parquet[C: Compression = Snappy]`  — per-page-compressed columnar.
#   - `Jsonl`                              — ndjson record stream, uncompressed.
#   - `Csv`                                — comma-separated, uncompressed.
#   - `Arrow`                              — Arrow IPC stream, uncompressed.
#   - `WholeFileCompressed[Inner, C]`      — whole-file codec wrapper.
# =============================================================================

from komira_core.arrow.compression import ArrowIpcCompression, Compression
from komira_core.arrow.compression_codecs import Snappy, Uncompressed, Zstd
from komira_core.arrow.quote_styles import QuoteStyle, Rfc4180
from komira_core.arrow.serde_format import CompressionModel, SerdeFormat
from komira_core.arrow.serde_format_options import (
    ArrowOptions,
    AvroOptions,
    CsvOptions,
    JsonOptions,
    OrcOptions,
    ParquetOptions,
)


# =============================================================================
# Parquet[C: Compression = Snappy]
# =============================================================================
#
# Per-page compression as a comptime type parameter (default Snappy matches
# DuckDB's `COPY ... (FORMAT parquet)` codec choice). There is no runtime
# `compression` field on ParquetOptions — codec choice is comptime-fixed per
# `LocalFormatSink[Parquet[C]]` instantiation.
# =============================================================================


@fieldwise_init
struct Parquet[C: Compression = Snappy](
    SerdeFormat, Copyable, Movable, Deinitable
):
    """Parquet on-disk format marker.

    `C: Compression` is a comptime type parameter — per-page compression
    codec. Default `Snappy` matches DuckDB / pyarrow / parquet-mr.
    Other valid bindings: `Parquet[Zstd]`, `Parquet[Zstd[19]]`,
    `Parquet[Uncompressed]`, `Parquet[Gzip]`, `Parquet[Gzip[9]]`, etc.

    Example:
        from komira_core.arrow.formats import Parquet
        from komira_core.arrow.compression_codecs import Zstd
        # later: LocalFormatSink[Parquet[Zstd]]("out.parquet")
        # later: LocalFormatSink[Parquet[Snappy]]("out.parquet")  # same as Parquet
    """

    var _reserved: Bool

    comptime Options = ParquetOptions
    # Parquet OWNS its codec (footer + per-page header drive dispatch);
    # WholeFileCompressed[Parquet[C], X] is illegal — double-wrap nonsense.
    comptime COMPRESSION_MODEL = CompressionModel.InternalRequired

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        return "parquet"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        return path.endswith(".parquet") or path.endswith(".pq")

    @staticmethod
    def default_options() -> ParquetOptions:
        return ParquetOptions()


# =============================================================================
# Jsonl — record-stream JSON (ndjson / JSON Lines)
# =============================================================================
#
# Uncompressed at the file level. For `.jsonl.gz`, use
# `WholeFileCompressed[Jsonl, Gzip]`.
# =============================================================================


@fieldwise_init
struct Jsonl(SerdeFormat, Copyable, Movable, Deinitable):
    """NDJSON / JSON Lines format marker. One JSON value per line.

    Uncompressed at the file level. For `.jsonl.gz` use
    `WholeFileCompressed[Jsonl, Gzip]`.

    NOTE: this is a yyjson-shape format. The reader/writer implementation
    lives in the JSON package.
    """

    var _reserved: Bool

    comptime Options = JsonOptions
    # Jsonl has no internal codec slot; compression via
    # WholeFileCompressed[Jsonl, C] (e.g. `.jsonl.gz` = WFC[Jsonl, Gzip]).
    comptime COMPRESSION_MODEL = CompressionModel.ExternalOnly

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        return "jsonl"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        return (
            path.endswith(".json")
            or path.endswith(".jsonl")
            or path.endswith(".ndjson")
        )

    @staticmethod
    def default_options() -> JsonOptions:
        return JsonOptions()


# =============================================================================
# Csv[Q: QuoteStyle = Rfc4180] — comma-separated values (RFC-4180-ish)
# =============================================================================
#
# `Csv` is parametric over a
# `Q: QuoteStyle` comptime parameter (Rfc4180 / Excel / Posix). Bare `Csv()`
# at constructor call sites resolves to `Csv[Rfc4180]` (default-parameter
# resolution at constructor-call sites works). Bare `Csv` at a TYPE-ARGUMENT
# position does NOT resolve, so callers spell `Csv[Rfc4180]` /
# `Csv[Excel]` / `Csv[Posix]` at every nested generic position.
#
# Uncompressed at the file level. For `.csv.gz` use
# `WholeFileCompressed[Csv[Rfc4180], Gzip[6]]`.
# =============================================================================


@fieldwise_init
struct Csv[Q: QuoteStyle = Rfc4180](
    SerdeFormat, Copyable, Movable, Deinitable
):
    """CSV format marker, parametric over QuoteStyle `Q` (default Rfc4180).

    `Q: QuoteStyle` selects the comptime dialect (RFC-4180 / Excel / Posix).
    Other valid bindings: `Csv[Excel]`, `Csv[Posix]`.

    Example:
        from komira_core.arrow.formats import Csv
        from komira_core.arrow.quote_styles import Excel
        # later: LocalFormatSink[Csv[Excel]]("out.csv")
        # later: LocalFormatSink[Csv[Rfc4180]]("out.csv")  # explicit form (= Csv())

    Uncompressed at the file level. For `.csv.gz` use
    `WholeFileCompressed[Csv[Rfc4180], Gzip[6]]`.
    """

    var _reserved: Bool

    comptime Options = CsvOptions
    # Csv has no internal codec slot; compression via
    # WholeFileCompressed[Csv[Q], C] (e.g. `.csv.gz` = WFC[Csv[Rfc4180], Gzip[6]]).
    comptime COMPRESSION_MODEL = CompressionModel.ExternalOnly

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        # Single name for the family; per-Q sub-name lives on Q.NAME.
        return "csv"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        return path.endswith(".csv") or path.endswith(".tsv")

    @staticmethod
    def default_options() -> CsvOptions:
        return CsvOptions()


# =============================================================================
# Arrow[C: ArrowIpcCompression = Uncompressed] — Arrow IPC stream / file
# =============================================================================
#
# Parametric on `C: ArrowIpcCompression` — the codec is comptime-fixed
# per `LocalFormatSink[Arrow[C]]` instantiation. The `ArrowIpcCompression`
# sub-trait (defined in `arrow.compression`) constrains `C` to
# only the codecs in Arrow IPC's `BodyCompression.codec` enum
# ({Uncompressed = -1 sentinel, Lz4Frame = 0, Zstd[level] = 1}).
# Compile-time prevents `Arrow[Snappy]` / `Arrow[Gzip]` / `Arrow[Lz4Raw]`
# (all wire-incorrect — not in the Arrow IPC enum).
#
# Default `Arrow[Uncompressed]` preserves zero-copy by default: the
# decoder can pointer-wrap an mmap span without memcpy.
#
# DISTINCT from `ArrowCStreamSink` (FFI buffer) — `Arrow[C]` here is the
# Arrow IPC FORMAT on disk (Stream and File formats).
# =============================================================================


@fieldwise_init
struct Arrow[C: ArrowIpcCompression = Uncompressed](
    SerdeFormat, Copyable, Movable, Deinitable
):
    """Arrow IPC stream marker (file-on-disk; NOT the FFI ArrowCStreamSink).

    `C: ArrowIpcCompression` is a comptime type parameter — per-buffer
    body compression codec. Default `Uncompressed` preserves zero-copy
    on reads (mmap-friendly pointer-wrap). Other valid
    bindings: `Arrow[Lz4Frame]`, `Arrow[Zstd[3]]`.

    Compile-time correctness: `C` is bound to `ArrowIpcCompression`
    (sub-trait of `Compression`); `Arrow[Snappy]` / `Arrow[Gzip]` etc.
    fail at compile-time (none of those codecs are in Arrow IPC's
    `BodyCompression.codec` enum).

    SinkVariant / SourceVariant carry 3 arms (Uncompressed / Lz4Frame /
    Zstd[3]); the read/write drivers handle the file format (footer +
    ARROW1 magic) and codec dispatch.
    """

    var _reserved: Bool

    comptime Options = ArrowOptions
    # Arrow IPC: spec supports optional body-stream compression (the typed
    # Arrow[C] form) AND whole-file wrap via WholeFileCompressed[Arrow, C].
    comptime COMPRESSION_MODEL = CompressionModel.InternalOptional

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        return "arrow"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        return (
            path.endswith(".arrow")
            or path.endswith(".arrows")
            or path.endswith(".ipc")
            or path.endswith(".feather")
        )

    @staticmethod
    def default_options() -> ArrowOptions:
        return ArrowOptions()


# =============================================================================
# Orc[C: Compression = Zstd[3]] — Apache ORC v1 (columnar, per-stream codec)
# =============================================================================
#
# DataFrame[O]-retirement A1. The ORC write path had no
# `SerdeFormat` conformer, so it was stuck on the legacy `ctx.write_orc(
# DataFrame[O], compression=Int)` sugar. This marker unblocks the typed write
# terminal `ScanFrame.to(FileSink[Orc[C]]) -> ctx.run(IoWriteSpec)` (walker-free)
# + the generic `ctx.write_rb[Orc[C]]`.
#
# `C: Compression` is a comptime type parameter — the per-stream ORC codec.
# `LocalFormatSink[Orc[C]].init_sink` maps `C` to the ORC CompressionKind enum
# int (NONE=0 / ZLIB=1 / SNAPPY=2 / LZ4=4 / ZSTD=5) at comptime (the same
# comptime->runtime bridge `Parquet[C]` uses for `PARQUET_CODEC_ID`, except the
# ORC CompressionKind int is not on the `Compression` trait so the sink resolves
# it via a `(C == X)` cascade). Default `Zstd[3]` matches
# `OrcWriterOptions.default()` (ORC_COMPRESSION_ZSTD) + the modern-ORC default.
#
# Wired codec bindings (`LocalFormatSink` arms): `Orc[Uncompressed]` (NONE),
# `Orc[Gzip[6]]` (ZLIB), `Orc[Snappy]`, `Orc[Lz4Raw]` (LZ4), `Orc[Zstd[3]]`.
# =============================================================================


@fieldwise_init
struct Orc[C: Compression = Zstd[3]](
    SerdeFormat, Copyable, Movable, Deinitable
):
    """Apache ORC on-disk format marker (columnar, per-stream compression).

    `C: Compression` is a comptime type parameter — the per-stream ORC codec.
    Default `Zstd[3]` matches `OrcWriterOptions.default()`. Other valid
    bindings: `Orc[Uncompressed]` (NONE), `Orc[Gzip[6]]` (ZLIB), `Orc[Snappy]`,
    `Orc[Lz4Raw]` (LZ4).

    Example:
        from komira_core.arrow.formats import Orc
        from komira_core.arrow.compression_codecs import Snappy
        # later: FileSink[Orc[Snappy]]("out.orc")
        # later: FileSink[Orc[Zstd[3]]]("out.orc")  # same as Orc
    """

    var _reserved: Bool

    comptime Options = OrcOptions
    # ORC OWNS its codec (PostScript compression field + per-stream chunk
    # framing drive dispatch); WholeFileCompressed[Orc[C], X] is illegal —
    # double-wrap nonsense.
    comptime COMPRESSION_MODEL = CompressionModel.InternalRequired

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        return "orc"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        return path.endswith(".orc")

    @staticmethod
    def default_options() -> OrcOptions:
        return OrcOptions()


# =============================================================================
# Avro[C: Compression = Uncompressed] — Apache Avro OCF (row, per-block codec)
# =============================================================================
#
# DataFrame[O]-retirement A1. Companion to `Orc[C]` for the Avro
# OCF write path. `C: Compression` is a comptime type parameter — the per-OCF-
# block codec. `LocalFormatSink[Avro[C]].init_sink` maps `C` to the AVRO_CODEC
# enum tag (NULL=0 / DEFLATE=1 / SNAPPY=2 / ZSTANDARD=5) at comptime via a
# `(C == X)` cascade. Default `Uncompressed` (AVRO_CODEC_NULL) matches
# `AvroWriterOptions.__init__` + `EngineContext.write_avro`'s default.
#
# Wired codec bindings (`LocalFormatSink` arms): `Avro[Uncompressed]` (NULL),
# `Avro[Gzip[6]]` (DEFLATE), `Avro[Snappy]`, `Avro[Zstd[3]]` (ZSTANDARD).
# =============================================================================


@fieldwise_init
struct Avro[C: Compression = Uncompressed](
    SerdeFormat, Copyable, Movable, Deinitable
):
    """Apache Avro OCF on-disk format marker (row-shape, per-block compression).

    `C: Compression` is a comptime type parameter — the per-OCF-block codec.
    Default `Uncompressed` (AVRO_CODEC_NULL). Other valid bindings:
    `Avro[Gzip[6]]` (DEFLATE), `Avro[Snappy]`, `Avro[Zstd[3]]` (ZSTANDARD).

    Example:
        from komira_core.arrow.formats import Avro
        from komira_core.arrow.compression_codecs import Snappy
        # later: FileSink[Avro[Snappy]]("out.avro")
        # later: FileSink[Avro[Uncompressed]]("out.avro")  # same as Avro
    """

    var _reserved: Bool

    comptime Options = AvroOptions
    # Avro OWNS its codec (OCF header `avro.codec` metadata + per-block codec
    # dispatch); WholeFileCompressed[Avro[C], X] is illegal — double-wrap
    # nonsense.
    comptime COMPRESSION_MODEL = CompressionModel.InternalRequired

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        return "avro"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        return path.endswith(".avro")

    @staticmethod
    def default_options() -> AvroOptions:
        return AvroOptions()


# =============================================================================
# WholeFileCompressed[Inner: SerdeFormat, C: Compression]
# =============================================================================
#
# Wraps an inner record-stream format `Inner` with a whole-file codec `C`.
# The inner format's record-level parse/encode runs over the
# C-decompressed byte stream; the codec is applied at the file boundary.
#
# Canonical uses:
#   - `WholeFileCompressed[Jsonl, Gzip]`         for `.jsonl.gz`
#   - `WholeFileCompressed[Csv[Rfc4180], Gzip]`  for `.csv.gz` (nested
#                                                 generic positions require
#                                                 fully-explicit Q binding)
#   - `WholeFileCompressed[Csv[Rfc4180], Zstd]`  for `.csv.zst`
#   - `WholeFileCompressed[Jsonl, Zstd]`         for `.jsonl.zst`
#
# Parquet does NOT use this wrapper — Parquet has per-page compression as
# `Parquet[C]`.
# =============================================================================


@fieldwise_init
struct WholeFileCompressed[Inner: SerdeFormat, C: Compression](
    SerdeFormat, Copyable, Movable, Deinitable
):
    """Whole-file codec wrapper. Pairs an inner record-stream format with
    a byte-stream codec applied at the file boundary.

    The Options associated type aliases the inner format's Options — the
    whole-file codec has no separate Options struct (compression level
    lives on `C` itself, e.g. `Zstd[19]`).

    `detect_extension(path)` is a two-suffix check: the outer codec's
    `FILE_EXTENSION` (e.g. `.gz`) THEN the inner format's recognized
    extensions (e.g. `.jsonl` / `.csv`). Empty `FILE_EXTENSION` is
    rejected at compile time would be sensible but `comptime if` over
    a `StaticString` `==` isn't trivial in Mojo 1.0.0b1; the runtime
    check just returns False for empty outer extension, which is
    correct behavior.
    """

    var _reserved: Bool

    comptime Options = Self.Inner.Options
    # The wrapper makes whatever was uncompressed-internally compressed-
    # externally. The result is itself an ExternalOnly composition (you
    # cannot double-wrap WholeFileCompressed[WholeFileCompressed[X, C1], C2]).
    comptime COMPRESSION_MODEL = CompressionModel.ExternalOnly

    def __init__(out self):
        self._reserved = False

    @staticmethod
    def name() -> StaticString:
        # Cannot easily compose StaticStrings at comptime in 1.0.0b1; return
        # a constant `"compressed"` marker. Callers needing precise names
        # can call `Inner.name()` and `C.NAME` separately.
        return "compressed"

    @staticmethod
    def detect_extension(path: String) -> Bool:
        # Empty outer extension: nonsense composition (use Inner directly).
        var ext_len = Self.C.FILE_EXTENSION.byte_length()
        if ext_len == 0:
            return False
        if not path.endswith(Self.C.FILE_EXTENSION):
            return False
        # Strip the outer-codec extension off the path tail and recurse
        # into the inner format's detect. Build the stripped path byte-by-
        # byte (String slicing not first-class in Mojo 1.0.0b1).
        var path_bytes = path.as_bytes()
        var keep = path.byte_length() - ext_len
        var stripped = String("")
        for i in range(keep):
            stripped += chr(Int(path_bytes[i]))
        return Self.Inner.detect_extension(stripped)

    @staticmethod
    def default_options() -> Self.Options:
        return Self.Inner.default_options()
