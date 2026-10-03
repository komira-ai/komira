# =============================================================================
# row_sort.mojo — slow-path row-format sort buffer
# =============================================================================
#
# Slow-path counterpart of the
# fast-path `SortBuffer[payload_col, *Keys]`. Used when:
#   * key arity > 4 (SortStageScaffold K_cap)
#   * keys contain non-fast DTypes
#   * non-keys-only / mixed-payload shapes outside the in-cube combos
#
# "Buffers rows; the comparator walks layout.key_descriptors
# column-by-column, calling per-DType compare kernels. Standard radix
# sort + ks-merge."
#
# A SINGLE struct backed by RowBlock + RowLayout
# (runtime-N), NOT a parametric variadic — same rationale as
# RowJoinBuildTable / RowHashAggTable.
#
# SCOPE: I64 keys (any arity 1..N) + I64 payloads (any arity 0..N)
# + per-key ASC/DESC direction. F64 / STRING keys + F64 payloads are
# future work (signatures hold via the DType-tag dispatch ladder;
# kernels are stubbed).
#
# Encapsulation invariants identical to row_block.mojo:
#   * Zero UnsafePointer in any public signature on RowSortBuffer.
#   * Zero wildcard origin.
#   * Zero unsafe_from_address.
#   * Zero ArcPointer.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.collections.batch_view import BatchView, ColView

from komira_row_format.row_block import (
    RowBlock,
    RowLayout,
    ColDescriptor,
    COL_FIXED,
    DT_I64,
)
from komira_row_format.arrow_row import (
    encode_row_keys_for_sort,
    arrow_row_compare,
    NULLS_FIRST,
    DT_I64 as ARROW_ROW_DT_I64,
)
from komira_row_format.row_sort_perm import (
    RowPermComparator,
    stable_insertion_sort_perm,
)


# =============================================================================
# Sort-direction tags
# =============================================================================

comptime SORT_ASC: UInt8 = 0
comptime SORT_DESC: UInt8 = 1


# =============================================================================
# RowSortBuffer — slow-path sort buffer
# =============================================================================


struct RowSortBuffer(Movable, Deinitable, RowPermComparator):
    """Slow-path sort buffer for runtime-N composite keys + payloads.

    Held as the slow-arm of `_SortVariant` on RBS (mutual
    exclusion of fast/slow is type-enforced by the Variant carrier).
    One instance per slow-path SORT segment.

    Fields:
        rows:               RowBlock of (key + payload) rows; one row
                            per logical sort input.
        sort_directions:    Per-key direction (SORT_ASC / SORT_DESC).
                            Length = `n_key_cols` in the bound layout.
        sorted_indices:     Output index permutation; produced by
                            `finalize_sort` and consumed by the
                            `emit_to_record_batch` drain.
        key_stride:         Cached key-row stride (bytes per key tuple);
                            == sum of key-col widths.

    NOTE: RowLayout is NOT embedded by value; it's held on a
    separate RBS slot under `Optional[OwnedPointer[RowLayout]]` and
    passed to `feed_batch` / `finalize_sort` / `emit_to_record_batch`
    via `ref [lo] RowLayout` — same shape across all morsel instances
    under one Tracer.

    Lifecycle:
      1. `__init__` with the fixed_row_stride from RowLayout.
      2. `add_key_direction` per declared key column.
      3. `feed_batch(batch, key_col_idxs, payload_col_idxs, layout)`
         per input batch — appends encoded rows to `self.rows`.
      4. `finalize_sort(layout)` materializes `self.sorted_indices`
         via a comparator over `layout.key_descriptors` + the per-key
         direction list.
      5. `emit_to_record_batch(layout, key_names, payload_names)`
         materializes the output RecordBatch in sorted order.
    """

    var rows: RowBlock
    var sort_directions: List[UInt8]
    var sorted_indices: List[Int]
    var key_stride: Int

    # -------------------------------------------------------------------------
    # Pre-encoded byte-lex sort keys.
    #
    # `_encoded_keys[r]` holds the arrow_row byte-lex encoding for row `r`
    # in `self.rows` (1:1 with row index — populated at `feed_batch` time).
    # `finalize_sort` swaps the per-cell-branching comparator
    # (`_compare_rows_i64`) for a single `arrow_row_compare(...)` call on
    # the pre-encoded byte strings; this is a memcmp-compatible byte-lex
    # comparison that collapses the K-keys-per-call cost to one byte-walk
    # over the constant-width encoding (~50-80 ms/query on Row-routed sort).
    #
    # `_encoded_keys_ready` is True iff the cached per-key dtype / asc /
    # null lists below match the bound RowLayout at finalize time. We
    # populate them on the first `feed_batch` call (we don't have the
    # layout at ctor time; RowLayout is held on a separate RBS slot).
    # -------------------------------------------------------------------------
    var _encoded_keys: List[List[UInt8]]
    var _arrow_row_key_col_idxs: List[Int]
    var _arrow_row_key_dtype_tags: List[UInt8]
    var _arrow_row_asc_flags: List[UInt8]
    var _arrow_row_nulls_first_flags: List[UInt8]
    var _arrow_row_is_null_zero: List[Bool]
    var _arrow_row_lists_ready: Bool

    def __init__(out self, key_stride: Int, fixed_row_stride: Int):
        """Empty-shell ctor.

        Args:
            key_stride: Bytes per key tuple (== sum of key-col widths).
                Cached for the comparator (which only reads key bytes).
            fixed_row_stride: Bytes per row in `rows` — `key_stride`
                plus sum of payload-cell widths.
        """
        self.rows = RowBlock(fixed_row_stride)
        self.sort_directions = List[UInt8]()
        self.sorted_indices = List[Int]()
        self.key_stride = key_stride
        # arrow_row key encoding — empty until first feed_batch.
        self._encoded_keys = List[List[UInt8]]()
        self._arrow_row_key_col_idxs = List[Int]()
        self._arrow_row_key_dtype_tags = List[UInt8]()
        self._arrow_row_asc_flags = List[UInt8]()
        self._arrow_row_nulls_first_flags = List[UInt8]()
        self._arrow_row_is_null_zero = List[Bool]()
        self._arrow_row_lists_ready = False

    def add_key_direction(mut self, direction: UInt8):
        """Append a per-key sort direction. Must be called once per key
        column declared on the layout, in the same order as the layout's
        `key_descriptors`.
        """
        self.sort_directions.append(direction)

    def n_rows(self) -> Int:
        """Number of buffered rows (== number of feed_batch input rows)."""
        return self.rows.n_rows

    def estimated_bytes(self) -> Int:
        """Rough in-memory footprint of the buffered rows + their pre-encoded
        byte-lex sort keys.

        The runtime-stage SORT spill
        coordinator polls this after each `feed_batch` to decide whether to
        spill the current run. Counts:
          * `rows`: `n_rows * fixed_row_stride` (the packed key+payload bytes).
          * `_encoded_keys`: the sum of per-row byte-lex key string lengths.
        Both are dominated by `rows` for narrow keys; the encoded-keys term is
        included so the estimate tracks total heap pressure. The List/Slab
        bookkeeping overhead is ignored (constant per row, immaterial at the
        budget scales spill targets).
        """
        var total = self.rows.n_rows * self.rows.fixed_row_stride
        for i in range(len(self._encoded_keys)):
            total += len(self._encoded_keys[i])
        return total

    def reset_keep_directions(mut self) raises:
        """Drain all buffered rows + pre-encoded keys, preserving the declared
        per-key sort directions + the cached arrow_row parameter lists.

        After the spill coordinator
        sorts + emits + spills the current run, it calls this to recycle the
        buffer for the next run rather than re-allocating a fresh `RowSortBuffer`
        (which would lose `sort_directions` + the lazily-populated arrow_row
        lists). The fixed_row_stride / key_stride are unchanged. Subsequent
        `feed_batch` calls append into the now-empty `rows` + `_encoded_keys`
        and skip the `_populate_arrow_row_lists` re-init (`_arrow_row_lists_ready`
        stays True).
        """
        var stride = self.rows.fixed_row_stride
        self.rows = RowBlock(stride)
        self.sorted_indices = List[Int]()
        self._encoded_keys = List[List[UInt8]]()

    def feed_batch[
        bo: Origin[mut=False], lo: Origin[mut=False], //,
    ](
        mut self,
        batch: BatchView[bo],
        key_col_idxs: List[Int],
        payload_col_idxs: List[Int],
        ref [lo] layout: RowLayout,
    ) raises:
        """Append one input batch's rows to `self.rows`.

        Hot loop (mirror of RowHashAggTable.upsert_batch
        encode-stage):
          Step 1 — encode each key + payload column into a per-batch
                   scratch RowBlock at offsets defined by `layout`.
          Step 2 — copy scratch[row] bytes into `self.rows[n_rows + row]`
                   in append order, advancing `self.rows.n_rows`.

        Scope: I64 keys + I64 payloads (any arity). Other DTypes
        raise (the lower_untyped routing predicate filters them).

        Caller invariants:
            * len(key_col_idxs) == layout.n_key_cols().
            * len(payload_col_idxs) == layout.n_payload_cols().
            * Every key col is DT_I64; every payload col is DT_I64.

        Parameters:
            bo: Origin of the input BatchView.
            lo: Origin of the borrowed RowLayout.
        """
        var n_rows_in = batch.n_rows()
        if n_rows_in == 0:
            return

        # ⛔⛔ STEP 0 — A NULL ANYWHERE IN A KEY OR PAYLOAD COLUMN IS REFUSED
        #. This buffer stores ONE 8-byte
        # I64 cell per column and NO validity: `write_i64_batch` copies the
        # data buffer, `_populate_arrow_row_lists` encodes every key as
        # NON-NULL, and `emit_to_record_batch` builds every output column with
        # no validity bitmap. A NULL was therefore not mis-placed, it was
        # ERASED — emitted as whatever payload sat in its slot (a parquet
        # decode writes 0 there), ordered as that value, with no row missing
        # and the right row count. The docstrings here and in the route that
        # feeds this buffer said "the layout / routing forbids nullable
        # keys"; this check enforces it at the one place every caller has
        # to pass through. Pinned by
        # `komira_row_format.tests.test_row_sort_buffer_refuses_nulls`.
        #
        # `col_any_null` walks the validity BITMAP (O(1) with no bitmap, one
        # 64-bit load per 64 rows with one), so a null-free column pays
        # nothing measurable; it never reads the data buffer.
        for k in range(len(key_col_idxs)):
            if batch.col_any_null(key_col_idxs[k], n_rows_in):
                raise Error(
                    "RowSortBuffer.feed_batch: sort key column "
                    + String(k)
                    + " (batch column "
                    + String(key_col_idxs[k])
                    + ") holds a NULL. This row-format buffer stores one I64"
                    " cell per column and NO validity, so it would erase the"
                    " NULL into its payload value rather than order it. Refused"
                    " rather than answered wrong; a nullable sort is served by"
                    " the resident column sort."
                )
        for p in range(len(payload_col_idxs)):
            if batch.col_any_null(payload_col_idxs[p], n_rows_in):
                raise Error(
                    "RowSortBuffer.feed_batch: payload column "
                    + String(p)
                    + " (batch column "
                    + String(payload_col_idxs[p])
                    + ") holds a NULL. This row-format buffer stores one I64"
                    " cell per column and NO validity, so it would emit the"
                    " NULL as its payload value. Refused rather than answered"
                    " wrong; a nullable sort is served by the resident column"
                    " sort."
                )

        # Step 1 — encode keys + payloads into a scratch RowBlock at the
        # layout's running offsets. We use a fresh per-batch scratch
        # (cheap — OwnedAlignedBuffer alloc once per batch + SIMD W=8 encode
        # for I64) so we don't have to re-encode into a streaming-append
        # RowBlock.
        var stride = layout.fixed_row_stride
        var scratch = RowBlock(stride)
        scratch.reserve_rows(n_rows_in)

        var n_key = layout.n_key_cols()
        for k in range(n_key):
            var desc = layout.key_descriptors[k]
            if desc.kind == COL_FIXED and desc.dtype_tag == DT_I64:
                var col = batch.col_i64(key_col_idxs[k])
                scratch.write_i64_batch(col, Int(desc.offset_in_row))
            else:
                raise Error(
                    "RowSortBuffer.feed_batch: I64-key"
                    " only; key col " + String(k)
                    + " has dtype_tag=" + String(Int(desc.dtype_tag))
                    + " (DT_I64=1 required)"
                )
        var n_payload = layout.n_payload_cols()
        for p in range(n_payload):
            var desc = layout.payload_descriptors[p]
            if desc.kind == COL_FIXED and desc.dtype_tag == DT_I64:
                var col = batch.col_i64(payload_col_idxs[p])
                scratch.write_i64_batch(col, Int(desc.offset_in_row))
            else:
                raise Error(
                    "RowSortBuffer.feed_batch: I64-payload"
                    " only; payload col " + String(p)
                    + " has dtype_tag=" + String(Int(desc.dtype_tag))
                    + " (DT_I64=1 required)"
                )

        # Step 2 — append scratch rows to self.rows, byte-copy stride
        # bytes per row.
        var prev_n = self.rows.n_rows
        self.rows.reserve_rows(prev_n + n_rows_in)
        for row in range(n_rows_in):
            self._copy_row_into_self(scratch, row, prev_n + row, stride)
        self.rows.set_n_rows(prev_n + n_rows_in)

        # Step 3 — encode per-row arrow_row
        # byte-lex sort keys for every row of this batch. The encoded byte
        # strings are appended in row order so `_encoded_keys[r]` aligns
        # 1:1 with `self.rows[r]`. The cached arrow_row parameter lists
        # are populated lazily on the first feed_batch (we don't have the
        # layout at __init__ time).
        if not self._arrow_row_lists_ready:
            self._populate_arrow_row_lists(key_col_idxs, layout)
        for row in range(n_rows_in):
            var enc = encode_row_keys_for_sort(
                batch,
                row,
                self._arrow_row_key_col_idxs,
                self._arrow_row_key_dtype_tags,
                self._arrow_row_asc_flags,
                self._arrow_row_nulls_first_flags,
                self._arrow_row_is_null_zero,
            )
            self._encoded_keys.append(enc^)

    def _populate_arrow_row_lists[lo: Origin[mut=False], //](
        mut self,
        key_col_idxs: List[Int],
        ref [lo] layout: RowLayout,
    ) raises:
        """Populate the cached arrow_row parameter lists on the first
        `feed_batch` invocation. Called once per RowSortBuffer lifetime.

        Encoded constants:
          * `key_dtype_tags` = DT_I64 per key (layout already enforces this
            via the lower_untyped routing predicate).
          * `asc_flags`      = self.sort_directions (caller-provided per
            add_key_direction).
          * `nulls_first_flags` = NULLS_FIRST per key (there is no
            per-key null-position). ⚠ It does NOT match the engine's default
            placement — `komira_core.plan.null_order_policy.derived_nulls_first`
            is NULLS LAST in both directions — and that is harmless ONLY because no NULL can
            reach the encode: `feed_batch` REFUSES a key or payload column
            holding one. ⛔ That refusal is the only thing that forbids
            nullable keys here — the other gates are DType gates — and
            without it a plain `ORDER BY k` over a nullable INT64 key through
            the bounded pull-stream ERASES its NULLs into their payload values.
          * `is_null_per_key`   = False per key — true by construction because
            of the `feed_batch` refusal.

        Raises on sort_directions length mismatch (matches finalize_sort
        invariant); the lower_untyped routing predicate guards the
        DT_I64-only invariant ahead of this call.
        """
        var n_key = layout.n_key_cols()
        if len(self.sort_directions) != n_key:
            raise Error(
                "RowSortBuffer._populate_arrow_row_lists:"
                " sort_directions length "
                + String(len(self.sort_directions))
                + " != layout.n_key_cols " + String(n_key)
                + " (caller must call add_key_direction once per key)"
            )
        if len(key_col_idxs) != n_key:
            raise Error(
                "RowSortBuffer._populate_arrow_row_lists:"
                " key_col_idxs length "
                + String(len(key_col_idxs))
                + " != layout.n_key_cols " + String(n_key)
            )
        self._arrow_row_key_col_idxs = List[Int](capacity=n_key)
        self._arrow_row_key_dtype_tags = List[UInt8](capacity=n_key)
        self._arrow_row_asc_flags = List[UInt8](capacity=n_key)
        self._arrow_row_nulls_first_flags = List[UInt8](capacity=n_key)
        self._arrow_row_is_null_zero = List[Bool](capacity=n_key)
        for k in range(n_key):
            var desc = layout.key_descriptors[k]
            # DT_I64 only. arrow_row.DT_I64 == 1 (mirror of
            # row_block.mojo; the cross-file invariant is locked by
            # the eval_test_arrow_row substrate test).
            if desc.dtype_tag != DT_I64:
                raise Error(
                    "RowSortBuffer._populate_arrow_row_lists:"
                    " I64-key only; key col "
                    + String(k)
                    + " has dtype_tag=" + String(Int(desc.dtype_tag))
                )
            self._arrow_row_key_col_idxs.append(key_col_idxs[k])
            self._arrow_row_key_dtype_tags.append(ARROW_ROW_DT_I64)
            self._arrow_row_asc_flags.append(self.sort_directions[k])
            self._arrow_row_nulls_first_flags.append(NULLS_FIRST)
            self._arrow_row_is_null_zero.append(False)
        self._arrow_row_lists_ready = True

    @always_inline
    def _copy_row_into_self(
        mut self,
        ref scratch: RowBlock,
        src_row: Int,
        dst_row: Int,
        stride: Int,
    ):
        """Copy `stride` bytes from `scratch[src_row]` to
        `self.rows[dst_row]`. Internal helper for feed_batch.

        SAFETY: both rows are bounded by their reserve_rows contracts
        (the caller invokes reserve_rows on both blocks). Receiver and
        scratch use distinct concrete origins; pointer arithmetic is
        confined to this internal helper.
        """
        # SAFETY: byte-by-byte copy under concrete origins. Both pointers
        # are obtained via the internal `_row_base_ptr_*` accessors which
        # widen to the receiver origin (concrete, not wildcard).
        var src = scratch._row_base_ptr_ro(src_row)
        var dst = self.rows._row_base_ptr_mut(dst_row)
        for i in range(stride):
            dst[i] = src[i]

    def finalize_sort[lo: Origin[mut=False], //](
        mut self,
        ref [lo] layout: RowLayout,
    ) raises:
        """Materialize `self.sorted_indices` via comparator-based sort.

        The per-row arrow_row
        byte-lex encoded keys (cached on `self._encoded_keys` at
        `feed_batch`) drive a single `arrow_row_compare(...)` per pair.
        This collapses the per-cell-branching K-key comparator
        (`_compare_rows_i64`) to one memcmp-compatible byte-walk over the
        constant-width encoding (~50-80 ms/query on Row-routed sort).

        ASC/DESC direction is baked into the encoded bytes at encode time
        (per-key DESC mode bit-inverts the encoded bytes; see
        `arrow_row.encode_row_keys_for_sort`). The comparator is direction-
        agnostic.

        Body: in-place stable sort (insertion sort for small N). A later
        perf upgrade could use pdqsort with byte-lex compare; the layout
        would be unchanged.

        Parameters:
            lo: Origin of the borrowed RowLayout.
        """
        var n = self.rows.n_rows

        var n_key = layout.n_key_cols()
        if len(self.sort_directions) != n_key:
            raise Error(
                "RowSortBuffer.finalize_sort: sort_directions length "
                + String(len(self.sort_directions))
                + " != layout.n_key_cols " + String(n_key)
                + " (caller must call add_key_direction once per key)"
            )
        # The arrow_row parameter lists must have been populated by
        # `feed_batch`. If finalize is called on a buffer that never saw
        # a feed (n=0 fast-pathed above), the lists are intentionally
        # empty — guard here so we don't read stale state from a
        # mismatched encode.
        if len(self._encoded_keys) != n:
            raise Error(
                "RowSortBuffer.finalize_sort: _encoded_keys length "
                + String(len(self._encoded_keys))
                + " != n_rows " + String(n)
                + " (feed_batch must populate arrow_row encoded keys"
                " 1:1 with self.rows)"
            )

        # Stable insertion-sort-over-index-permutation via the shared
        # `stable_insertion_sort_perm[C]` driver (row_sort_perm.mojo). The
        # per-pair comparison stays here (`compare` → arrow_row byte-lex over
        # the pre-encoded keys), comptime-monomorphized via the
        # `RowPermComparator` conformance — no runtime fn-ptr in the hot loop.
        # A future version could upgrade the driver to pdqsort (comparator unchanged).
        self.sorted_indices = stable_insertion_sort_perm(n, self)

    @always_inline
    def compare(self, row_a: Int, row_b: Int) raises -> Int:
        """`RowPermComparator` conformance — arrow_row byte-lex compare
        of the pre-encoded sort keys for rows `row_a` / `row_b`. Per-key
        ASC/DESC direction is baked into the encoded bytes at `feed_batch` time,
        so this comparator is direction-agnostic (mirrors `finalize_sort`'s
        prior inline `arrow_row_compare` call). Comptime-monomorphized at the
        shared sort helper's call site."""
        return arrow_row_compare(
            self._encoded_keys[row_a], self._encoded_keys[row_b]
        )

    @always_inline
    def _compare_rows_i64(
        self,
        row_a: Int,
        row_b: Int,
        key_offsets: List[Int],
        key_dirs: List[UInt8],
    ) -> Int:
        """Return -1 if row_a < row_b, +1 if row_a > row_b, 0 if equal
        (after applying per-key directions). Walks keys left-to-right;
        returns on the first non-equal key.

        Scope: I64 keys only. Per-DType dispatch lands in a future version.
        """
        var n_key = len(key_offsets)
        for k in range(n_key):
            var off = key_offsets[k]
            var va = self.rows.read_fixed[DType.int64](row_a, off)
            var vb = self.rows.read_fixed[DType.int64](row_b, off)
            if va == vb:
                continue
            var asc_less = va < vb
            if key_dirs[k] == SORT_ASC:
                if asc_less:
                    return -1
                else:
                    return 1
            else:
                # SORT_DESC: invert
                if asc_less:
                    return 1
                else:
                    return -1
        return 0

    def emit_to_record_batch[
        lo: Origin[mut=False], //,
    ](
        self,
        ref [lo] layout: RowLayout,
        key_names: List[String],
        payload_names: List[String],
    ) raises -> Optional[RecordBatch]:
        """Drain the sorted rows into a fresh RecordBatch.

        Output schema: [key_cols..., payload_cols...] in the order given
        by `key_names` + `payload_names`. All values are I64.

        Per `self.sorted_indices` (produced by `finalize_sort`):
        rebuild a column-oriented output where row[i] of the output
        is `self.rows[self.sorted_indices[i]]`.

        Returns:
            Some(rb) with n_rows == self.rows.n_rows; None if no rows.
        """
        var n = self.rows.n_rows
        if n == 0:
            return None
        var n_key = layout.n_key_cols()
        var n_payload = layout.n_payload_cols()
        if len(key_names) != n_key:
            raise Error(
                "RowSortBuffer.emit_to_record_batch: key_names length "
                + String(len(key_names)) + " != layout.n_key_cols "
                + String(n_key)
            )
        if len(payload_names) != n_payload:
            raise Error(
                "RowSortBuffer.emit_to_record_batch: payload_names length "
                + String(len(payload_names)) + " != layout.n_payload_cols "
                + String(n_payload)
            )
        if len(self.sorted_indices) != n:
            raise Error(
                "RowSortBuffer.emit_to_record_batch: sorted_indices not"
                " populated — caller must invoke finalize_sort() first"
            )

        var sb = SchemaBuilder()
        for k in range(n_key):
            sb.add_field(Field(String(key_names[k]), ArrowType.INT64, False))
        for p in range(n_payload):
            sb.add_field(
                Field(String(payload_names[p]), ArrowType.INT64, False)
            )
        var schema = sb.build()

        var rbb = RecordBatchBuilder.with_capacity(n_key + n_payload)

        # Emit key columns in sorted order.
        for k in range(n_key):
            var desc = layout.key_descriptors[k]
            var off = Int(desc.offset_in_row)
            var values = List[Scalar[DType.int64]](capacity=n)
            for i in range(n):
                var src_row = self.sorted_indices[i]
                var v = self.rows.read_fixed[DType.int64](src_row, off)
                values.append(v)
            rbb.add_column(
                Column.from_primitive[DType.int64](
                    PrimitiveArray[DType.int64].from_list(values)
                )
            )

        # Emit payload columns in sorted order.
        for p in range(n_payload):
            var desc = layout.payload_descriptors[p]
            var off = Int(desc.offset_in_row)
            var values = List[Scalar[DType.int64]](capacity=n)
            for i in range(n):
                var src_row = self.sorted_indices[i]
                var v = self.rows.read_fixed[DType.int64](src_row, off)
                values.append(v)
            rbb.add_column(
                Column.from_primitive[DType.int64](
                    PrimitiveArray[DType.int64].from_list(values)
                )
            )

        var rb = rbb.build(schema^)
        return Optional[RecordBatch](rb^)
