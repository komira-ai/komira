# =============================================================================
# komira_scan_planning.reader_factory — ReaderFactory trait
# =============================================================================
#
#
# Format-side trait whose associated `Reader` type is the per-file reader
# struct. `open(fs, path)` parses the footer (or hits a cache held INSIDE
# the conformer), opens the persistent fd, and constructs the Reader in
# one shot.
#
# v0.1 conformer: `ParquetReaderFactory` (in komira_parquet/parquet_reader_factory.mojo).
# v0.2+ conformers: `OrcReaderFactory`, `ArrowIpcReaderFactory`.
#
# Why a TRAIT (vs free function or method on ParquetFormat):
#
# Layering note: a natural sketch
# has `open(...)` take `mut footer_cache: ParquetMetadataCache`
# as a method arg. That literal shape would inject a `komira_parquet`
# dep onto `komira_fs`, inverting the package dep graph
# (`komira_fs` is lower than `komira_parquet`). To preserve the layering,
# this implementation moves the cache out of the trait's method
# signature and onto the conformer's INTERNAL state instead — see
# `ParquetReaderFactory` in komira_parquet/parquet_reader_factory.mojo
# (which holds the cache via Pointer with a tracked origin and consults
# it inside the body of its own `open`). The trait surface stays
# format-agnostic; v0.2+ ORC factories follow the same pattern with
# their own format-specific cache.
#
# Pointer discipline:
#   * No UnsafePointer in any method signature.
#   * Reader returned by-value (Movable; caller stores in Slab).
# =============================================================================

from komira_arrow.schema import Schema, RecordBatch
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.arrow_types import ArrowType

from komira_fs.byte_range import ByteRange
from komira_fs.file_system import FileSystem

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr

# LAYERING CUT: `komira_scan_planning` does not name
# `komira_morsel.HashAggDecodedRG`. The trait's fused-hash-agg return type is
# now an associated type bounded by `HashAggDecodedLike` below, whose method
# signatures name only the core packages / `komira_collections` types. See that
# trait's docstring for why.
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab


trait FilterPayloadResultLike(Movable, Deinitable):
    """return-type trait for
    `Reader.decode_filter_and_payload`.

    Conformers carry two row-aligned RecordBatches and expose them via
    `take_filter()` / `take_payload()`. The trait shape sidesteps Mojo
    0.26.3's lack of `tup[i]^` partial-move on `Tuple[T1, T2]` for
    non-Copyable T's by routing both extractions through method calls
    (which Mojo CAN dispatch through the associated-type bound).

    Method-extraction order: take_filter() first, then take_payload().
    Subsequent take calls are undefined; the result struct is intended
    to be consumed in one place at the call site.
    """

    def take_filter(mut self) -> RecordBatch:
        ...

    def take_payload(mut self) -> RecordBatch:
        ...


trait HashAggDecodedLike(Movable, Deinitable):
    """LAYERING CUT — return-type trait for
    `Reader.decode_for_hash_agg`, the exact sibling of
    `FilterPayloadResultLike` above and introduced for the same reason at a
    different altitude.

    WHY THIS TRAIT EXISTS. Declaring the method below as
    `... raises -> Optional[HashAggDecodedRG]`, with `HashAggDecodedRG`
    imported from the morsel package, would put that package in
    `komira_scan_planning`'s dep closure — and because it sits just above the
    foundational filesystem layer that scan code consumes, and a Mojo
    consumer must carry every transitive `-I` root, it would land on the
    consume-time `-I` list of every library above, including ones that
    never name a morsel symbol.

    A trait cannot fix that by living in `komira_morsel` (async would still
    import it) and `HashAggDecodedRG` cannot conform to a trait declared HERE
    (that inverts the same edge, pointing the other way). So the shape is the
    one `FilterPayloadResultLike` already established: the trait is declared in
    the LOW package and names only types the low package can already see, and
    the conformer is a small struct declared in the HIGH package that produces
    the value. `ParquetHashAggDecoded` in
    `komira_parquet/parquet_reader.mojo` is that conformer;
    `komira_parquet` legitimately depends on BOTH sides and rebuilds the
    `HashAggDecodedRG` from these pieces at the one call site that needs it.

    Every method below returns a core-package / `komira_collections` /
    stdlib type, which is what keeps this trait declarable here at all.

    Method-extraction contract: each `take_*` consumes its inner `Optional`.
    Take each exactly once, then drop the (now empty) wrapper. Subsequent
    calls are undefined — same rule as `FilterPayloadResultLike`.
    """

    def take_key_array(mut self) -> PrimitiveArray[DType.int64]:
        """Move out the decoded Int64 group-by key column."""
        ...

    def take_hashes(mut self) -> SharedAlignedBuffer[HeapRegion]:
        """Move out the per-row UInt64 hash buffer (stride 8)."""
        ...

    def take_fingerprints(mut self) -> SharedAlignedBuffer[HeapRegion]:
        """Move out the per-row UInt8 fingerprint buffer (stride 1)."""
        ...

    def take_partition_ids(mut self) -> List[UInt8]:
        """Move out the per-row partition ids, each in [0, N_PARTITIONS)."""
        ...

    def take_agg_input_columns(mut self) -> Slab[Column[HeapRegion]]:
        """Move out the decoded agg-input columns, in requested order."""
        ...

    def num_rows(self) -> Int:
        """Row count — matches every per-row buffer's logical length.

        Read-only (not a `take_*`), so it stays valid before the takes and
        lets the caller size the reconstructed payload without re-deriving
        the count from a moved-out buffer.
        """
        ...


# `Reader.unit_column_selection_class` answers.
comptime SELECTION_DECLINES: Int = 0
comptime SELECTION_FIXED_WIDTH: Int = 1
comptime SELECTION_VAR_WIDTH: Int = 2


trait Reader(Movable, Deinitable):
    """Per-file reader trait — the dispatch shape.

    Exposes the 9 hot-path methods that the source struct dispatches
    through `self._readers[file_idx].X(...)` plus the
    `unit_count_for_file()` ctor-helper. Mirrors today's
    `FormatDiscovery` per-unit method surface but drops the explicit
    `file_idx` arg — a `Reader` IS the file.

    v0.1 conformer: `ParquetReader` (in
    `komira_parquet/parquet_reader.mojo`).
    v0.2+ conformers: `OrcReader`, `ArrowIpcReader`.

    Design note: an alternative where `ParquetReader` does NOT conform to
    a Reader trait does not work — Mojo
    0.26.3's elaborator does not resolve method dispatch on a generic
    `Self.RF.Reader` value without trait bounds, so the source struct's
    `self._readers[file_idx].decode_columns_subset(...)` body cannot
    compile against an associated type with only `Movable &
    Deinitable` bounds. The trait below earns its keep
    immediately (resolves the elaborator constraint) and matches the
    v0.2 ORC drop-in shape the spec described as "premature" but
    unblocks v0.1.

    Pointer discipline: no UnsafePointer in any method signature.
    """

    @always_inline
    def unit_count_for_file(self) -> Int:
        """Total work-unit (row-group) count for this file. Used by the
        source's ctor to compute the cumulative work-unit total across
        N readers.
        """
        ...

    @always_inline
    def unit_num_rows(self, unit_in_file: Int) -> Int:
        """Number of rows in row-group `unit_in_file`."""
        ...

    @always_inline
    def unit_num_columns(self, unit_in_file: Int) -> Int:
        """Number of physical columns in row-group `unit_in_file`."""
        ...

    def unit_column_selection_class(
        self, unit_in_file: Int, col_idx: Int, preserve_dict: Bool,
    ) -> Int:
        """How a ROW-SELECTIVE decode (`decode_columns_subset_selected`) would
        treat physical column `col_idx` of unit `unit_in_file`:

          * `SELECTION_DECLINES` (0) — the conformer's selective kernel is
            known to refuse this column's shape (so a caller should not even
            try: a refused all-or-nothing attempt wastes the columns decoded
            before it);
          * `SELECTION_FIXED_WIDTH` (1) — accepted; fixed-width values, whose
            full decode is a memcpy, so selecting buys little;
          * `SELECTION_VAR_WIDTH` (2) — accepted; variable-width values
            (strings / binary), whose full decode copies every body — the
            shape a selective decode pays off on.

        A cost HINT, never a correctness input: every caller still honours a
        `None` from the selective decode. A conformer that cannot tell returns
        `SELECTION_DECLINES`.
        """
        ...

    def unit_byte_range(
        self, unit_in_file: Int,
    ) raises -> ByteRange:
        """Canonical (offset, length) byte range for row-group
        `unit_in_file`."""
        ...

    def can_prune_unit(
        self, unit_in_file: Int, expr: Expr,
    ) raises -> Bool:
        """Stats-pruning test against `expr`. Returns True iff column-
        chunk statistics PROVE `expr` excludes every row in the unit.
        """
        ...

    def unit_all_match(
        self, unit_in_file: Int, expr: Expr,
    ) raises -> Bool:
        """DUAL of `can_prune_unit`: True iff column-chunk statistics
        PROVE `expr` is satisfied by EVERY row in the unit.

        `can_prune_unit` answers "no row here can match" (skip the unit
        entirely); this answers "every row here matches" — so a
        COUNT-only scan may contribute `unit_num_rows(unit_in_file)`
        straight from the footer and decode nothing.

        Conservative in the opposite direction to its dual: returns
        FALSE on ANY ambiguity (missing/None stats, nulls present or
        unknown, unsupported predicate shape or column type). A
        spurious TRUE would MISCOUNT, so "prove it or decline" is the
        whole contract.

        Formats with no per-unit statistics should always return False
        — the default behavior is correct (decode normally).
        """
        ...

    def can_prune_unit_by_bloom(
        self, unit_in_file: Int, expr: Expr,
    ) raises -> Bool:
        """Bloom-filter pruning test against `expr`. Returns True iff
        column-chunk SBBF blooms PROVE the EQ leaves of `expr` cannot
        match any row in the unit.

        Slot:.

        Conservative — returns False on any ambiguity (no bloom on
        column, unsupported predicate shape, cross-impl writer hash
        mismatch). Callers should run this AFTER `can_prune_unit`
        (stats are free; bloom probe costs one extra pread per
        column).

        Self is immutable — the underlying pread API (positional
        per-call offset+length, no shared cursor) is thread-safe
        and side-effect-free at the Reader-level.

        Formats without bloom-filter support (ORC reader v0.1, Arrow
        IPC) should always return False from this method — the
        default behavior is correct conservative no-prune.
        """
        ...

    def build_arrow_schema_for_file(self) raises -> Schema:
        """Build the file's Arrow Schema."""
        ...

    def column_name_to_idx_for_file(
        self, name: String,
    ) raises -> Int:
        """Resolve a leaf column name to a 0-based file column index.
        Returns -1 when not found."""
        ...

    def advise_prefetch_next(
        self, next_unit_in_file: Int, col_indices: List[Int], mode: Int,
    ) raises -> None:
        """Best-effort kernel readahead hint for the next row-group, scoped to
        the FILE column indices `col_indices` the scan will decode.

        ⛔ THE COLUMN LIST IS PART OF THE CONTRACT. An implementation that
        ignores it advises the wrong bytes, and because `madvise` is a HINT
        that changes no value and no row count, nothing downstream can notice
        — see `komira_parquet.parquet_source_helpers._advise_prefetch_next_rg`
        for the 492 MB/rep of `watch_id` this shape once read ahead for a
        query that projects `event_date`."""
        ...

    def read_unit_bulk_bytes(
        self, offset: Int, length: Int,
    ) raises -> SharedAlignedBuffer[HeapRegion]:
        """Bulk pread `length` bytes from `offset`."""
        ...

    def decode_columns_subset(
        self, unit_in_file: Int,
        col_indices: List[Int], preserve_dict: Bool,
    ) raises -> RecordBatch:
        """Decode the columns at `col_indices` from row-group
        `unit_in_file`."""
        ...

    def decode_columns_subset_arena(
        mut self, unit_in_file: Int,
        col_indices: List[Int], preserve_dict: Bool,
    ) raises -> RecordBatch:
        """decode `col_indices` from row-group
        `unit_in_file` through the conformer's OWN reusable decode context, so
        the per-RG large decode buffers (decompression scratch + dict-index
        codes) RECYCLE across the row groups this (per-worker) Reader decodes,
        instead of allocating + freeing per RG.

        Behaviorally IDENTICAL to `decode_columns_subset` — same decoded result,
        byte-for-byte. The ONLY difference is buffer provenance (recycled vs
        fresh). Primitives-only signature so the trait stays free of any
        conformer-specific type. Conformers without a recyclable context MAY
        no-op this by delegating to `decode_columns_subset`.
        """
        ...

    def decode_columns_subset_selected(
        self, unit_in_file: Int,
        col_indices: List[Int], preserve_dict: Bool,
        mask: BooleanArray,
    ) raises -> Optional[RecordBatch]:
        """Masked payload decode: decode `col_indices`
        from unit `unit_in_file` materialising ONLY the rows that `mask` keeps.

        Returns `Some(RecordBatch)` of `popcount(mask)` rows — ALREADY
        gathered, in `col_indices` order — when the conformer could honour the
        selection for EVERY requested column. Returns `None` otherwise, and the
        caller MUST then fall back to `decode_columns_subset*` followed by a
        post-hoc gather. Both halves are required to produce the same rows;
        only the strategy differs, which is what makes this an A/B-able lever
        rather than a semantic change.

        ⛔ `None` is the correct answer for a conformer that cannot skip decode
        work, and it costs nothing: there is no partial credit, because a
        RecordBatch whose columns disagreed on row count cannot be built.
        Formats without a selection-bearing decode (ORC v0.1, Arrow IPC, CSV,
        JSONL) should return `None` unconditionally.

        Primitives-only signature — `BooleanArray` and `RecordBatch` are both
        already in this trait's vocabulary, so no conformer-specific type
        crosses the surface.
        """
        ...

    def decode_columns_by_name_remap(
        self, unit_in_file: Int,
        result_names: List[String],
        result_types: List[ArrowType],
        preserve_dict: Bool,
    ) raises -> RecordBatch:
        """decode a row-group into the RESULT-schema
        slots resolved BY NAME against THIS file's footer.

        For each result column name, resolve this file's leaf index by name;
        present columns decode at the resolved index, absent columns get a
        typed all-null vector. The output batch's column order + schema match
        the RESULT schema independent of this file's physical column ORDER —
        the fix for the multi-file reorder/drift silent-data-corruption
        hazard. Conformers MAY fast-path to a positional decode when the
        by-name remap is the identity (all files identical — common case).
        """
        ...

    comptime HashAggDecoded: HashAggDecodedLike
    """LAYERING CUT: the conformer's fused-hash-agg return type
    for `decode_for_hash_agg`, bound to a concrete struct by each conformer
    (`ParquetReader` binds `ParquetHashAggDecoded`). Must conform to
    `HashAggDecodedLike` so the generic source body can move the pieces out
    through trait dispatch.

    This associated type is what replaced a direct
    `from komira_morsel.hash_agg_decoded import HashAggDecodedRG` in this
    file — see `HashAggDecodedLike` above for the dep-graph reason.
    """

    def decode_for_hash_agg(
        self,
        unit_in_file: Int,
        key_col_idx: Int,
        agg_input_col_indices: List[Int],
        preserve_dict: Bool,
    ) raises -> Optional[Self.HashAggDecoded]:
        """Decode-fused hash agg.

        Decode the group-by key column + agg-input columns from
        row-group `unit_in_file`, then precompute per-row hashes /
        fingerprints / partition_ids over the L1-cached key bytes.

        Returns:
          * `Some(Self.HashAggDecoded)` for a non-empty RG.
          * `None` for an empty RG (caller skips morsel emission).

        Single-Int64-key contract enforced by the planner before
        `caps.hash_agg_key_col_idx` is set.

        Conformers without a fused decode path MAY no-op this by
        falling through to a normal `decode_columns_subset` and
        constructing the payload from the result; this trait
        method exists primarily to let the parquet conformer
        amortize the hash-precompute over its decode pass.
        """
        ...

    def fused_dict_count(
        self, unit_in_file: Int, col_idx: Int, op: UInt8, threshold: Int64,
    ) raises -> Optional[Int]:
        """fused filter+count over a numeric-dictionary
        column WITHOUT materializing the per-row values.

        For an INT32/INT64 dictionary-encoded `col_idx` in row-group
        `unit_in_file`, conformers MAY decode only the codes + distinct dict
        entries, build a per-entry boolean LUT for `value <op> threshold`, and
        count `lut[code]` over the codes — skipping the flat-value gather, the
        SIMD mask, and the separate popcount.

        Returns:
          * `Some(count)` when the column matched the numeric-dict fast-path
            shape (INT32/INT64 dict, no PLAIN-fallback pages). The count is
            EXACT: NULL rows are absent from the codes and never satisfy a
            comparison predicate, so they correctly contribute zero.
          * `None` when the column did NOT match — the caller MUST fall back
            to the safe `decode_columns_subset` + predicate-eval + true_count
            path.

        `op` is one of the six scalar comparison ops; `threshold` is the int
        literal RHS. The signature is primitives-only so the trait stays free
        of any arrow / compiler / parquet type dependency.

        Conformers without a numeric-dict fast path MAY no-op this by always
        returning `None` (the caller then takes the safe path).
        """
        ...

    def fused_dict_survivors(
        self, unit_in_file: Int, col_idx: Int, op: UInt8, threshold: Int64,
    ) raises -> Optional[List[Int]]:
        """REST-LATE-MAT leg 2: fused filter -> survivor ROW-INDEX
        list over a numeric-dictionary column WITHOUT materializing the per-row
        values — the mask/gather sibling of `fused_dict_count` (which counts).

        For an INT32/INT64 dictionary-encoded `col_idx` in row-group
        `unit_in_file`, conformers MAY decode only the codes + distinct dict
        entries, build a per-entry boolean LUT for `value <op> threshold`, and
        collect the row indices where `lut[code]` fires — skipping the flat-value
        gather for the FILTER column. The indices equal
        `filter_to_indices(predicate-eval over the flat column)`, so gathering a
        payload by them yields the SAME rows as the flat decode-then-eval path.

        Returns:
          * `Some(indices)` ONLY when the column matched the numeric-dict
            fast-path shape AND has NO nulls in this RG (codes are row-aligned
            1:1 with the output). A NULL row would compact out of the codes and
            break the alignment, so nullable columns decline.
          * `None` otherwise — the caller MUST fall back to the safe
            `decode_columns_subset` + predicate-eval path (null-correct + every
            other shape).

        Primitives-only (`List[Int]`) so the trait stays free of any arrow /
        compiler / parquet type dependency (mirrors `fused_dict_count`).
        Conformers without a numeric-dict fast path MAY no-op this by always
        returning `None`.
        """
        ...

    comptime FilterPayloadResult: FilterPayloadResultLike
    """The conformer's pair-batch return type for
    `decode_filter_and_payload`. Bound to a concrete struct (e.g.
    `ParquetReader.FilterPayloadBatches`) by each conformer. Must
    conform to `FilterPayloadResultLike` so the source body can call
    `take_filter()` / `take_payload()` through the trait dispatch.

    F introduces this associated type to sidestep
    Mojo 0.26.3's lack of partial-move support on `Tuple[T1, T2]` for
    non-Copyable `Ti` — the conformer-defined struct wraps fields in
    `Optional` to enable `take()`-style extraction at the call site.
    """

    def decode_filter_and_payload(
        mut self,
        unit_in_file: Int,
        filter_cols: List[Int],
        payload_cols: List[Int],
        preserve_dict: Bool,
        ref filter: Expr,
        allow_partial_prune: Bool = False,
    ) raises -> Optional[Self.FilterPayloadResult]:
        """payload-coordinated partial-prune
        decode.

        Decodes `filter_cols` AND `payload_cols` using ONE shared
        partial-prune pick computation, returning row-aligned batches
        suitable for downstream eval + gather.

        Same behavioral contract as `decode_columns_subset_with_filter`
        but extends it to the projection-≠-filter case:

          * `Some((filter_batch, payload_batch))` — both batches share
            the same row count. `payload_batch` is empty-schema /
            count-only when `payload_cols.is_empty()` (collapses to
            the count-only case, returns the same filter_batch +
            placeholder).
          * `None` — page-prune proves zero rows match.

        `allow_partial_prune`:
          When True, multi-pred-col conjunction + payload-coordination
          may fire (returns row-shrunk batches). When False, falls
          back to two whole-column reads; the caller's existing eval
          + gather logic operates unchanged.

        Conformers without page-index support MAY no-op
        this by routing through two `decode_columns_subset` calls and
        returning `Some((fb, pb))` unconditionally.

        Pointer / lifetime: `filter` borrowed Expr, lifetime rooted at
        caller's ExprPool. Conformer must NOT retain past method call.
        """
        ...

    def decode_columns_subset_with_filter(
        mut self, unit_in_file: Int,
        col_indices: List[Int], preserve_dict: Bool,
        ref filter: Expr,
        allow_partial_prune: Bool = False,
    ) raises -> Optional[RecordBatch]:
        """D / 1.E.1 — page-prune-aware decode
        entry.

        Same semantics as `decode_columns_subset`, but the conformer
        MAY consult per-column page-index statistics to short-circuit
        when the filter `Expr` proves zero rows in the row-group match.

        Contract:
          - `Some(batch)` — normal decode. The batch's row count is
            either:
              (a) the full RG row count when partial-prune is not
                  exercised (all-pass / fallback / `allow_partial_prune
                  == False`), OR
              (b) a strict subset (partial-prune fired) — equivalent
                  to "decode the full column then keep only the rows
                  in the surviving pages". Only possible when
                  `allow_partial_prune == True`.
          - `None` — page-prune proves the entire row-group is empty
            under this filter. The caller must skip emission of a
            morsel for this RG.

        `allow_partial_prune`:
          When True, the conformer MAY return a row-shrunk batch on
          partial-prune (case (b) above). The caller must have
          verified a pre-condition that makes a row-shrunk return
          safe — typically `payload_cols.is_empty()` (no payload
          column whose row-alignment with the predicate column
          would otherwise be required for late-materialization
          gather correctness). When False (default), the conformer
          MUST return a full-RG batch on partial-prune (it can still
          page-prune internally for byte savings as long as the
          returned row count matches `decode_columns_subset`'s).

        Conformers without page-index support MAY
        no-op this by routing through `decode_columns_subset` and
        returning `Some(batch)` unconditionally — the trait method
        is correctness-equivalent to the unfiltered path; the only
        win the conformer surrenders is the page-prune short-circuit.

        Pointer / lifetime: `filter` is a borrowed Expr, lifetime
        rooted at the caller's ExprPool (the source struct's `expr_o`
        origin parameter tracks it). The conformer must NOT retain the
        ref past the method call.
        """
        ...


trait ReaderFactory(Movable, Deinitable):
    """Format-side factory: turns a (FS, path) pair into a per-file
    Reader. The Reader holds parsed format-specific metadata + a
    persistent fd + the format-specific decode body.

    One conformer per format (v0.1: ParquetReaderFactory).
    v0.2+: OrcReaderFactory, ArrowIpcReaderFactory.

    Pointer discipline: no UnsafePointer in any method signature.
    Reader returned by-value; caller-side code stores into a Slab.
    """

    comptime FS: FileSystem
    """the factory's
    FileSystem conformer, now a STRUCT-level associated type (was a
    method-generic `open[FS]`). Required so the associated `Reader`
    type can be FS-parametric (`ParquetReader[Self.FS]`) — the engine
    path needs the Reader to carry the S3Fs's `dispatch_o`
    origin, which a method-generic FS cannot express through a fixed
    `Self.Reader` associated type. The source binds the factory's
    `FS` to its own `FS` at the alias site
    (`ParquetReaderFactory[cache_o, FS]`)."""

    comptime Reader: Reader
    """The per-file reader type. Conforms to the `Reader` trait above
    (which exposes the 9 hot-path methods + `unit_count_for_file`).

    Bound to `ParquetReader[Self.FS]` by `ParquetReaderFactory[cache_o, FS]`.

    NOT Copyable: the Reader owns a unique fd / cloud handle.
    Movable so it can flow out of `open(...)` and into the source's
    Slab.
    """

    def open(
        mut self,
        mut fs: Self.FS,
        path: String,
    ) raises -> Self.Reader:
        """Construct a Reader for `path` using `fs` (the factory's
        FS conformer) as the bytes backend.

        The cache (if any) is held on the conformer's internal state
        and consulted inside this method; trait surface is
        cache-agnostic. v0.1 `ParquetReaderFactory` holds the
        EngineContext-scoped `ParquetMetadataCache` via
        Pointer with a tracked origin.

        `FS` is the factory's STRUCT-level associated type so
        the returned `Self.Reader = ParquetReader[Self.FS]` carries the
        FS origin. The source binds the factory's FS to its own FS.
        """
        ...

    def clone_reader_for_worker(
        self,
        reader: Self.Reader,
    ) raises -> Self.Reader:
        """produce ANOTHER worker's Reader for
        the file `reader` already opened — SHARING every piece of per-file
        READ-ONLY state and duplicating nothing.

        The source builds a Reader per `[worker][file]`. Row 0 goes through
        `open`; every row after goes through here. A conformer MUST share the
        read-only state (the file mapping, the parsed footer, the footer bytes
        — all refcount bumps) and MUST give the clone FRESH per-worker MUTABLE
        state (its own FS handle / transport, its own decode arena and
        per-file caches), because the two Readers are handed to different
        pthreads.

        WHY IT EXISTS. `open` mmaps the WHOLE file on the mmap-backed arm, so
        an N-worker scan of one file used to hold N independent mappings of
        identical read-only bytes, all of which the DRIVER `munmap`s SERIALLY
        at query teardown — for a large file and a wide pool, a measurable
        share of the query's serial residual. The per-worker Reader is still right
        worker a disjoint cloud transport and a private decode arena — but a
        `MAP_PRIVATE + PROT_READ` view of an immutable file is neither of those
        things, so its duplication was collateral, not a design.

        This is why the method lives on the FACTORY and not on `Reader`: Mojo
        cannot dispatch a `-> Self`-returning trait method on an associated-type
        VALUE (`RF.Reader`), but `Self.Reader` in the factory's own signature —
        the same shape `open` already uses — resolves.
        """
        ...

    def open_footer_only(
        mut self,
        mut fs: Self.FS,
        path: String,
    ) raises -> Self.Reader:
        """Construct a FOOTER-ONLY Reader for `path`: the parsed format
        metadata (row-group counts + schema, from the conformer's cache)
        paired with a placeholder file body that performs NO eager mmap /
        fd open.

        For a `df.slice(offset, length)` row-window scan the source only
        DECODES the 1-2 row groups the window overlaps, yet the ctor must
        still know EVERY file's row-group count (to size the flat-RG
        cursor) and schema (for the by-name union). This method supplies
        both from the cached footer WITHOUT the per-file eager mmap that
        `open` pays — at N files that eager mmap, not the tiny decode, is
        the row-window latency wall. The returned Reader must NEVER be
        decoded (the window caps skip its row groups); doing so is a
        contract violation (the placeholder file has no readable bytes).
        """
        ...
