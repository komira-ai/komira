# =============================================================================
# Per-format Options structs for SerdeFormat conformers
# =============================================================================
#
# Per-format runtime knobs (codec choice on Parquet is NOT runtime — it is
# the `C` type parameter on `Parquet[C]`; row-group size + dictionary are
# runtime).
#
# Each conformer's `default_options()` static factory returns one of these
# (or `ArrowOptions` for the `Arrow` IPC marker — currently zero-field).
#
# All four structs must satisfy `Movable & Copyable & ImplicitlyCopyable` —
# the trait bound on `SerdeFormat.Options` (§2.1). `@fieldwise_init` synthesizes
# the positional and copy/take ctors; the zero-arg `fn __init__(out self)`
# below sets defaults.
# =============================================================================

from komira_arrow.schema import Schema


# 128 MiB default row-group target — matches the DuckDB / pyarrow default and
# the Parquet writer's own `DEFAULT_ROW_GROUP_SIZE_BYTES`.
# Duplicated here so arrow need not depend on the Parquet package
# (dependency direction: parquet -> arrow). The two constants must stay in sync.
comptime DEFAULT_ROW_GROUP_SIZE_BYTES: Int = 128 * 1024 * 1024


@fieldwise_init
struct ParquetOptions(Movable, Copyable, ImplicitlyCopyable):
    """Parquet write/read knobs.

    NOTE: `compression` is not on this struct — the codec is a
    comptime type parameter on `Parquet[C: Compression = Snappy]`.
    The remaining knobs (row_group_target_bytes, dictionary)
    are runtime-tunable; codec choice is comptime-fixed per
    `LocalFormatSink[Parquet[C]]` instantiation.

    Defaults mirror the `ParquetSink.__init__` ctor:
      - row_group_target_bytes: ~128 MiB (DEFAULT_ROW_GROUP_SIZE_BYTES).
      - dictionary: True (dict-encode low-cardinality strings).
    """

    var row_group_target_bytes: Int
    var dictionary: Bool

    def __init__(out self):
        self.row_group_target_bytes = DEFAULT_ROW_GROUP_SIZE_BYTES
        self.dictionary = True


@fieldwise_init
struct JsonOptions(Movable, Copyable, ImplicitlyCopyable):
    """JSON write/read knobs.

    Defaults:
      - lines_mode: False  (default = JSON ARRAY; True = NDJSON / JSONL).
      - pretty: False      (compact, single-line output).

    NOTE: a read-side `schema` field is NOT carried on this struct — wide-default
    schema inference happens at the source layer. Adding `Optional[Schema]` here
    would require `Schema` to be `ImplicitlyCopyable`, which it isn't; the
    upgrade path is to widen Schema's trait conformance and then add the field.
    """

    var lines_mode: Bool
    var pretty: Bool

    def __init__(out self):
        self.lines_mode = False
        self.pretty = False


@fieldwise_init
struct CsvOptions(Movable, Copyable, ImplicitlyCopyable):
    """CSV write/read knobs.

    Defaults mirror `CsvSink.__init__`:
      - delimiter: b','
      - header: True
      - quote: b'"'

    Reader-specific knobs (skip_rows, null_str) are not carried here yet.
    """

    var delimiter: UInt8
    var header: Bool
    var quote: UInt8

    def __init__(out self):
        self.delimiter = UInt8(ord(","))
        self.header = True
        self.quote = UInt8(ord('"'))


@fieldwise_init
struct ArrowOptions(Movable, Copyable, ImplicitlyCopyable):
    """Arrow IPC stream write/read knobs.

    Currently zero fields. Adding fields later (compression at the IPC
    framing level, footer metadata) is additive and does not break the
    `default_options()` contract.

    A zero-field struct is still `Movable & Copyable & ImplicitlyCopyable`
    — the trait bound on `SerdeFormat.Options` (§2.1).
    """

    # Placeholder field — Mojo 1.0.0b1 requires at least one field for
    # @fieldwise_init to synthesize sensible ctors. The field is byte-padded
    # away by the compiler when unused, and the default is `False`. Future
    # versions can repurpose this (e.g. as `compress_buffers: Bool`) without
    # breaking the binary layout (one-byte field).
    var _reserved: Bool

    def __init__(out self):
        self._reserved = False


@fieldwise_init
struct OrcOptions(Movable, Copyable, ImplicitlyCopyable):
    """Apache ORC write/read knobs.

    v2.3 NOTE: the ORC CompressionKind codec is NOT a runtime field — it is a
    comptime type parameter on `Orc[C: Compression = Zstd[3]]` (§2.2.1), exactly
    like `Parquet[C]`. The `LocalFormatSink[Orc[C]]` init arm maps `C` to the ORC
    CompressionKind enum int (NONE=0 / ZLIB=1 / SNAPPY=2 / LZ4=4 / ZSTD=5) at
    comptime, so codec choice is fixed per instantiation.

    The remaining knob is runtime-tunable:
      - row_index_stride: rows per stride / stripe (default 10000, matching
        `OrcWriterOptions.default()` and `EngineContext.write_orc`).
    """

    var row_index_stride: Int

    def __init__(out self):
        self.row_index_stride = 10000


@fieldwise_init
struct AvroOptions(Movable, Copyable, ImplicitlyCopyable):
    """Apache Avro OCF write/read knobs.

    v2.3 NOTE: the Avro block codec is NOT a runtime field — it is a comptime
    type parameter on `Avro[C: Compression = Uncompressed]` (§2.2.1). The
    `LocalFormatSink[Avro[C]]` init arm maps `C` to the AVRO_CODEC enum tag
    (NULL=0 / DEFLATE=1 / SNAPPY=2 / ZSTANDARD=5) at comptime, so codec choice
    is fixed per instantiation.

    The remaining knob is runtime-tunable:
      - emit_arrow_logicals: stamp `arrow.*` annotations on lossy Arrow types
        so they round-trip (default True, matching `AvroWriterOptions` and
        `EngineContext.write_avro`).
    """

    var emit_arrow_logicals: Bool

    def __init__(out self):
        self.emit_arrow_logicals = True
