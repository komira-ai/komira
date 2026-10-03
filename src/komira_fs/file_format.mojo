# =============================================================================
# komira_fs.file_format — Layered FileFormat traits
# =============================================================================
# A 3-layer architecture (FileFormat umbrella + ColumnarReader + RowReader)
# with capability discovery through an alias-bool fallback (Mojo
# 0.26.3 trait-conformance limits).
#
# The 3-layer split:
#
#                           ┌──────────────────────────┐
#                           │  FileFormat (umbrella)    │
#                           │   identity + schema       │
#                           └─────────┬────────────────┘
#                                     ▲
#                       ┌─────────────┴─────────────┐
#                       │                           │
#               ┌───────┴──────────┐    ┌───────────┴────────┐
#               │ ColumnarReader   │    │   RowReader        │
#               │  (column batch)  │    │   (row iterator)   │
#               └───────┬──────────┘    └────────────────────┘
#                       ▲
#                  (7 Has* capability sub-traits
#                   that previously extended ColumnarReader were deleted
#                   as unreachable v0.1 placeholder surface; the 7
#                   alias-bool flags HAS_PREDICATE_PUSHDOWN etc. on the
#                   FileFormat umbrella below remain as v0.2+ advertise
#                   hooks. v0.1 capability dispatch lives inline in the
#                   ColumnarMultiConsumerSource source body, not at the
#                   format trait surface.)
#
# Capability dispatch (alias-bool fallback shape):
#   Mojo 0.26.3 does NOT support `@parameter if FMT is HasPredicatePushdown`
#   (no compile-time trait-conformance check across the codebase as of
#   compile-time trait-conformance check). The shape used by
#   FileFormat conformers today is the alias-bool fallback: every conformer
#   overrides `alias HAS_PREDICATE_PUSHDOWN: Bool = True`; engine
#   dispatch (when v0.2 wires it) reads via
#   `@parameter if FMT.HAS_PREDICATE_PUSHDOWN: ...`. This is provably
#   supported by Mojo 0.26.3 and used widely for static
#   compile-time config flags.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any method signature.
#   * Bytes carrier is `List[UInt8]`; ByteRange is the existing POD.
#   * `Self.Schema` / `Self.ColumnBatch` / `Self.Row` / `Self.RowIter`
#     bind to typed Movable+Deinitable values; conformers
#     pick concrete types.
# =============================================================================

from komira_fs.byte_range import ByteRange
from komira_fs.column_set import ColumnSet


# =============================================================================
# FileFormat — umbrella trait (Layer 1)
# =============================================================================
#
# Identity + schema parsing only. Every concrete file format
# (Parquet, Avro, JSON, CSV, ORC, ArrowIPC) conforms to FileFormat;
# the columnar / row split lives on the sub-traits.
#
# Capability flags:
#   `HAS_PREDICATE_PUSHDOWN`, `HAS_DYNAMIC_JOIN_FILTER`, `HAS_BLOOM_FILTER`,
#   `HAS_DICT_PRESERVATION`, `HAS_LATE_MATERIALIZATION`. Default to False
#   on FileFormat so any conformer that doesn't opt in advertises False
#   automatically; ParquetFormat overrides each to True.
#
# Why on the umbrella, not on each sub-trait:
#   The engine's dispatch site does `@parameter if FMT.HAS_PREDICATE_PUSHDOWN`
#   on the FMT type parameter — that parameter is constrained to
#   `ColumnarReader` or `RowReader` typically, but the alias must be
#   resolvable from any FileFormat-conforming type. Putting the bools on
#   the umbrella means every conformer (columnar or row) automatically
#   advertises its capability set without having to re-implement the
#   flags per sub-trait.
# =============================================================================


trait FileFormat(Movable, Deinitable):
    """Umbrella file-format trait. Identity (extension, magic-byte
    detection) + schema parsing.

    Layer-1 of the 3-layer architecture (see file header). Every
    concrete format conforms here; columnar formats additionally
    conform to `ColumnarReader`, row formats to `RowReader`,
    capability-bearing formats to the relevant sub-traits in
    `file_format_capabilities.mojo`.

    Associated types:
      * `Schema` — format's logical schema representation. Bound to
        `ParquetSchemaBundle` / `AvroSchema` / etc. by concrete impls.

    Capability flags:
      Each capability defaults to False on the umbrella. Conformers that
      implement a capability override the corresponding flag to True
      AND conform to the matching sub-trait in
      `file_format_capabilities.mojo`. Engine dispatch uses
      `@parameter if FMT.HAS_X` to compile the right arm.

    Pointer discipline:
      * No UnsafePointer in any method signature.
      * Bytes carrier is `List[UInt8]`.
    """

    comptime Schema: Movable & Deinitable

    # Capability advertisement aliases (alias-bool fallback shape per
    #). All default False; conformers override.
    comptime HAS_PREDICATE_PUSHDOWN: Bool = False
    comptime HAS_DYNAMIC_JOIN_FILTER: Bool = False
    comptime HAS_BLOOM_FILTER: Bool = False
    comptime HAS_DICT_PRESERVATION: Bool = False
    comptime HAS_LATE_MATERIALIZATION: Bool = False
    # Step 3a trait-spec gap closure: 2 additional capability flags.
    comptime HAS_BYPASS_COLUMNS: Bool = False
    comptime HAS_COUNT_ONLY: Bool = False

    def extension_hint(self) -> String:
        """The canonical filename extension for this format — e.g.
        ".parquet", ".avro", ".csv", ".json". Used by URI-scheme dispatch
        when picking a format for `file://` paths.

        Instance method (not @staticmethod) per Mojo 0.26.3 trait-
        elaboration constraints — staticmethods on traits don't
        consistently elaborate via the conformance check. Concrete
        impls return a const string."""
        ...

    def detect_format(self, header_bytes: List[UInt8]) -> Bool:
        """Best-effort magic-byte detection. Conformers either compare
        against a magic prefix (Parquet "PAR1", Avro "Obj\\x01") or
        return True unconditionally for header-less formats (CSV,
        JSON Lines)."""
        ...

    def parse_schema(
        self,
        header_bytes: List[UInt8],
    ) raises -> Self.Schema:
        """Parse format-specific header bytes into a typed Schema.
        Sync — bytes are already in memory, parsing is bounded.

        For Parquet, `header_bytes` is the file footer (fetched by
        the FileSystem layer). For Avro, magic + schema JSON. For
        CSV, the first line."""
        ...


# =============================================================================
# ColumnarReader — Layer 2a (columnar interface)
# =============================================================================
#
# Columnar formats (Parquet, ORC, Arrow IPC) implement this. Decode is
# column-projection-aware via `ColumnSet` so unrequested columns can
# skip-decode.
# =============================================================================


trait ColumnarReader(FileFormat):
    """Columnar-format reader interface. Decodes a (bytes, range)
    pair into an Arrow ColumnBatch projected to a column subset.

    Layer-2 of the 3-layer architecture (extends FileFormat).
    Conformers: ParquetFormat (v0.1), OrcFormat (v0.2+), ArrowIpcFormat
    (v0.2+). NOT conformed by row-only formats (CsvFormat, AvroFormat).

    `read_columnar` is the canonical immutable-self method — workers
    call concurrently via `MultiConsumerSource.process_unit`. The
    conformer's decode body must hold ONLY immutable / atomic state;
    no per-call mutation of `self` allowed.

    Pointer discipline (mirrors FileFormat).
    """

    comptime ColumnBatch: Movable & Deinitable

    def read_columnar(
        self,
        bytes: List[UInt8],
        range: ByteRange,
        projection: ColumnSet,
    ) raises -> Optional[Self.ColumnBatch]:
        """Decode `bytes` (covering the file's `range`) projected to
        the columns in `projection`. Returns None when the byte slice
        doesn't yield a complete batch — the caller should accumulate
        more bytes and retry (streaming-discovery extension; v0.1
        always returns Some on success).

        IMMUTABLE self — workers call concurrently. Format must hold
        only Atomic / immutable state on `self`.
        """
        ...


# =============================================================================
# RowReader — Layer 2b (row-iterator interface)
# =============================================================================
#
# Row-format (CSV, JSON Lines, Avro records). The interface returns an
# iterator that yields rows on demand.
#
# v0.1 surface notes:
#   * `Row` is the per-row payload type (concrete-format chooses).
#   * `RowIter` is the iterator type. Mojo 0.26.3 doesn't have a
#     mature Iterator trait that we can require here, so RowIter is
#     just `Movable & Deinitable`; conformers expose the
#     `next()` method on their concrete iterator type. The engine's
#     row-source operator is parameterized by FMT and calls
#     `iter.next()` directly.
# =============================================================================


trait RowReader(FileFormat):
    """Row-format reader interface. Opens an iterator over rows in a
    (bytes, range) pair.

    Layer-2 of the 3-layer architecture (extends FileFormat).
    Conformers: ParquetFormat (default delegate via internal columnar
    pivot, v0.1), CsvFormat (v0.2+), AvroFormat (v0.2+).

    `Row` is the format's per-row payload — Parquet synthesizes row
    tuples; CSV emits `List[String]`; Avro emits typed-record values.
    `RowIter` is the format-specific iterator state machine.
    """

    comptime Row: Movable & Deinitable
    comptime RowIter: Movable & Deinitable

    def open_row_iter(
        self,
        bytes: List[UInt8],
        range: ByteRange,
    ) raises -> Self.RowIter:
        """Open a row-by-row iterator over `bytes`. The iterator
        yields `Optional[Self.Row]` — None at EOF.

        IMMUTABLE self — multi-consumer compatible. The iterator
        itself is per-call state (mutated freely); only the format
        instance must be sharable.
        """
        ...
