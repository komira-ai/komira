# =============================================================================
# komira_sdk_exec/file_source.mojo -- `FileSource[F]`, a file-read source
#   parametric on the serde format `F`.
# =============================================================================
#
# WHAT THIS IS. `FileSource[F: SerdeFormat]` is the read-side counterpart of
# a format-parametric file sink. It holds one concrete source per format and
# answers the `SourceLike` questions (`schema`, `estimate_rows`, `fingerprint`,
# `supports_filter_pushdown`) by asking that source.
#
# WHICH FORMATS ARE WIRED.
#   - `Parquet[Uncompressed]`, `Parquet[Snappy]`, `Parquet[Zstd[3]]`,
#     `Parquet[Gzip[6]]` and `Parquet[Lz4Raw]` wrap a `ParquetSource`. The codec
#     parameter only names the codec a write would emit: the per-page codec is
#     read from the Parquet footer at decode time, so every Parquet arm behaves
#     the same.
#   - `Jsonl` wraps a `JsonSource`, built from the caller's schema (JSON has no
#     footer to read a schema from).
#   - Every other format (`Csv`, `Arrow`, `WholeFileCompressed`) holds no
#     source: `schema()` is an empty `Schema`, `estimate_rows()` is -1,
#     `fingerprint()` is 0 and `supports_filter_pushdown` is False. Nothing
#     raises, so a caller must not use those instantiations to read.
#
# STORAGE. `_FileSourceState[F]` keeps two `Optional` arms, `parquet_source`
# and `json_source`; the comptime cascade in `FileSource.__init__` fills the
# one that matches `F` and leaves the other `None`. `parquet_source_view` and
# `json_source_view` return copies of the arm, so a caller can lift it into a
# `SourceVariant`. `FileSource.from_path` reads the Parquet footer once and
# returns a `SourceVariant` over a `ParquetSource` with the footer's schema.
#
# No `UnsafePointer` appears in any signature.
# =============================================================================


from komira_compression.compression import ArrowIpcCompression, Compression
from komira_compression.compression_codecs import (
    Gzip,
    Lz4Frame,
    Lz4Raw,
    Snappy,
    Uncompressed,
    Zstd,
)
from komira_arrow.formats import (
    Arrow,
    Csv,
    Jsonl,
    Parquet,
    WholeFileCompressed,
)
from komira_arrow.serde_format import SerdeFormat

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_scan_source.parquet_source import ParquetSource
# `FileSource[Jsonl]` delegates to `JsonSource`, a columnar source whose
# materializer emits Arrow batches directly.
from komira_scan_source.json_source import JsonSource
from komira_scan_source.source_like import SourceLike
from komira_scan_source.source_variant import SourceVariant


# =============================================================================
# _FileSourceState[F] — per-format reader state
# =============================================================================


struct _FileSourceState[F: SerdeFormat](
    Movable, Copyable, Deinitable
):
    """Per-format reader state for `FileSource[F]`.

    Exactly one arm is `Some` after construction; the rest stay `None`.
    Mirrors the storage shape of `SourceVariant`.

    Two arms exist: Parquet (`ParquetSource`) and Jsonl (`JsonSource`).
    Other formats leave both `None`, and the `FileSource` accessors then
    return their empty answers.
    """

    var parquet_source: Optional[ParquetSource]
    # JsonSource arm for `FileSource[Jsonl]`. Parallel to
    # `parquet_source`: exactly one Optional arm holds `Some` after
    # construction; the comptime cascade in `FileSource.__init__`
    # populates the matching arm based on `F`.
    var json_source: Optional[JsonSource]

    def __init__(out self):
        self.parquet_source = Optional[ParquetSource](None)
        self.json_source = Optional[JsonSource](None)

    def copy(self) -> Self:
        var out = _FileSourceState[Self.F]()
        if self.parquet_source:
            out.parquet_source = Optional[ParquetSource](
                self.parquet_source.value().copy()
            )
        if self.json_source:
            out.json_source = Optional[JsonSource](
                self.json_source.value().copy()
            )
        return out^


# =============================================================================
# FileSource[F: SerdeFormat]
# =============================================================================


struct FileSource[F: SerdeFormat](
    SourceLike, Movable, Copyable, Deinitable
):
    """Parametric file-read source. Wraps a `ParquetSource` or a
    `JsonSource` behind one type parametric on `F`.

    Two ways to build one:
      - Explicit: `FileSource[Parquet[Snappy]](path, schema)`.
      - Auto-detect: `file_source("in.parquet")` -> `SourceVariant`
        (`source_factories.mojo`), or `FileSource[...].from_path(path)`
        for a path known to be Parquet.

    For Parquet, the caller supplies the parsed Schema upfront (the footer
    must have been read; this mirrors the `ParquetSource(path, schema)`
    constructor). `from_path(path)` reads the footer itself.

    Implements `SourceLike` (schema / estimate_rows / fingerprint /
    supports_filter_pushdown) — comptime-narrowed delegation to the
    active arm, through accessor methods that read it.
    """

    var path: String
    var options: Self.F.Options
    var _state: _FileSourceState[Self.F]

    def __init__(
        out self,
        var path: String,
        var schema: Schema,
        var options: Self.F.Options = Self.F.default_options(),
        mtime_ns: UInt64 = 0,
    ):
        """Construct a FileSource from a path + Schema + Options.

        For Parquet: the Schema is the data schema parsed from the
        footer; the caller is responsible for the footer read.
        `from_path(path)` does this internally.

        For Jsonl: the Schema is the caller-supplied column shape. For the
        other formats the state stays empty.
        """
        self.path = path^
        self.options = options^
        self._state = _FileSourceState[Self.F]()
        comptime if (
            (Self.F == Parquet[Uncompressed])
            or (Self.F == Parquet[Snappy])
            or (Self.F == Parquet[Zstd[3]])
            or (Self.F == Parquet[Gzip[6]])
            # `Lz4Raw` is the fifth wired Parquet codec. LZ4_RAW is a
            # per-page codec read from the footer, so every arm here is
            # codec-agnostic once the ParquetSource exists: the type
            # parameter only names which codec a write would emit. Leaving
            # it out of this cascade would not raise: the accessors would
            # return an empty `Schema()`, `estimate_rows() == -1`,
            # `fingerprint() == 0` and `supports_filter_pushdown() == False`.
            or (Self.F == Parquet[Lz4Raw])
        ):
            self._state.parquet_source = Optional[ParquetSource](
                ParquetSource(String(self.path), schema^, name=None, mtime_ns=mtime_ns)
            )
        elif (Self.F == Jsonl):
            # Jsonl arm delegates to JsonSource. The caller-supplied schema
            # is the column shape the columnar materializer emits; JSON has
            # no embedded footer schema.
            self._state.json_source = Optional[JsonSource](
                JsonSource(String(self.path), schema^, mtime_ns=mtime_ns)
            )
        # Any other format leaves the state empty.

    def copy(self) -> Self:
        """Deep-clone the active arm."""
        var out = FileSource[Self.F](
            String(self.path),
            Schema(),  # placeholder; overwritten by _state copy below
            self.options,
            mtime_ns=UInt64(0),
        )
        out._state = self._state.copy()
        return out^

    # =========================================================================
    # SourceLike trait conformance — comptime-narrowed delegation
    # =========================================================================

    def schema(self) -> Schema:
        """Return the source's structural schema."""
        comptime if (
            (Self.F == Parquet[Uncompressed])
            or (Self.F == Parquet[Snappy])
            or (Self.F == Parquet[Zstd[3]])
            or (Self.F == Parquet[Gzip[6]])
            # `Lz4Raw` is the fifth wired Parquet codec; see the ctor arm.
            or (Self.F == Parquet[Lz4Raw])
        ):
            if self._state.parquet_source:
                return self._state.parquet_source.value().schema()
            return Schema()
        elif (Self.F == Jsonl):
            # Jsonl arm delegates to JsonSource.schema() (the
            # caller-supplied schema).
            if self._state.json_source:
                return self._state.json_source.value().schema()
            return Schema()
        else:
            return Schema()

    def estimate_rows(self) -> Int:
        """Row-count hint from the active arm; -1 = unknown."""
        comptime if (
            (Self.F == Parquet[Uncompressed])
            or (Self.F == Parquet[Snappy])
            or (Self.F == Parquet[Zstd[3]])
            or (Self.F == Parquet[Gzip[6]])
            # `Lz4Raw` is the fifth wired Parquet codec; see the ctor arm.
            or (Self.F == Parquet[Lz4Raw])
        ):
            if self._state.parquet_source:
                return self._state.parquet_source.value().estimate_rows()
            return -1
        elif (Self.F == Jsonl):
            # JsonSource.estimate_rows() returns -1 (unknown): JSON has no
            # embedded row-count metadata without a full structural scan.
            if self._state.json_source:
                return self._state.json_source.value().estimate_rows()
            return -1
        else:
            return -1

    def fingerprint(self) -> UInt64:
        """Stable identity hash from the active arm."""
        comptime if (
            (Self.F == Parquet[Uncompressed])
            or (Self.F == Parquet[Snappy])
            or (Self.F == Parquet[Zstd[3]])
            or (Self.F == Parquet[Gzip[6]])
            # `Lz4Raw` is the fifth wired Parquet codec; see the ctor arm.
            or (Self.F == Parquet[Lz4Raw])
        ):
            if self._state.parquet_source:
                return self._state.parquet_source.value().fingerprint()
            return UInt64(0)
        elif (Self.F == Jsonl):
            # JsonSource.fingerprint() returns FNV-1a-64 over path +
            # folded mtime, so a rewritten file changes the fingerprint.
            if self._state.json_source:
                return self._state.json_source.value().fingerprint()
            return UInt64(0)
        else:
            return UInt64(0)

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """Per-predicate pushdown delegate to active arm."""
        comptime if (
            (Self.F == Parquet[Uncompressed])
            or (Self.F == Parquet[Snappy])
            or (Self.F == Parquet[Zstd[3]])
            or (Self.F == Parquet[Gzip[6]])
            # `Lz4Raw` is the fifth wired Parquet codec; see the ctor arm.
            or (Self.F == Parquet[Lz4Raw])
        ):
            if self._state.parquet_source:
                return self._state.parquet_source.value().supports_filter_pushdown(
                    predicate
                )
            return False
        elif (Self.F == Jsonl):
            # JsonSource.supports_filter_pushdown() returns False for
            # every predicate (JSON has no decode-time pruning — filters
            # become deferred OP_FILTER on the materialized batch).
            if self._state.json_source:
                return self._state.json_source.value().supports_filter_pushdown(
                    predicate
                )
            return False
        else:
            return False

    # =========================================================================
    # Direct access to the underlying ParquetSource (for callers that need
    # to build a ScanData / SourceVariant directly).
    # =========================================================================

    def parquet_source_view(self) -> Optional[ParquetSource]:
        """Return a copy of the underlying ParquetSource if the active
        arm is Parquet[*], else None. A caller building a `SourceVariant`
        uses this to lift the source into one.
        """
        if self._state.parquet_source:
            return Optional[ParquetSource](
                self._state.parquet_source.value().copy()
            )
        return Optional[ParquetSource](None)

    def json_source_view(self) -> Optional[JsonSource]:
        """Return a copy of the underlying JsonSource if the active
        arm is Jsonl, else None.

        Parallel to `parquet_source_view()`; a caller building a
        `SourceVariant` consumes this accessor to lift a `FileSource[Jsonl]`
        into the JSON `SourceVariant` arm.
        """
        if self._state.json_source:
            return Optional[JsonSource](
                self._state.json_source.value().copy()
            )
        return Optional[JsonSource](None)

    # =========================================================================
    # from_path(path) — footer-codec auto-discovery factory
    # =========================================================================
    #
    # For Parquet[C] specializations, opens the file, reads the footer, derives
    # the Arrow Schema, then constructs a SourceVariant holding a
    # ParquetSource with that schema. The per-page codec is read from the
    # footer by the Parquet decoder when the file is decoded; the
    # SourceVariant surface itself is codec-agnostic (one
    # Optional[ParquetSource] arm).
    #
    # The comptime `C: Compression` parameter is documentation only: the
    # codec used at decode time is what the footer says. If the declared `C`
    # differs from the footer's codec, the read still works.
    # =========================================================================

    @staticmethod
    def from_path(var path: String) raises -> SourceVariant:
        """Open `path`, read the Parquet footer once, return a SourceVariant
        carrying a ParquetSource with the footer-derived Arrow Schema.

        Companion to `source_factories.file_source(path)` (which auto-detects
        the format from the extension and dispatches here for `.parquet*`
        paths). Use this static form when the caller has already established
        the file is Parquet and wants to keep the typed `Parquet[C]` form for
        documentary clarity:

            var sv = FileSource[Parquet[Zstd[3]]].from_path("in.parquet")
            ctx.read_source(sv^)

        The per-page codec used at decode time is what the column metadata
        says; the declared `C` is documentary only.

        Args:
            path: Path to a Parquet file. Consumed.

        Returns:
            A `SourceVariant` carrying a `ParquetSource`. Pass to
            `ctx.read_source(sv^)` to get a DataFrame.

        Raises:
            Error if the file is unreadable, the magic bytes are invalid,
            or footer parsing fails.
        """
        # Read the footer once; the cost is O(metadata size) and no data page
        # is touched.
        from komira_sdk.parquet_footer import read_parquet_footer
        var footer = read_parquet_footer(path)
        var schema = footer.take_schema()
        var src = ParquetSource(String(path), schema.copy())
        return SourceVariant(src^)
