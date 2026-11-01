# =============================================================================
# sort_external_merge -- the k-way merge of sorted runs: run cursors, the
# comparator over their heads, and the merge into output batches
# =============================================================================
#
# `k_way_merge_cursors` merges N sorted runs (each one or more batches) with
# the loser tree (`sort_loser_tree`) and materializes every
# `output_batch_size` merged rows with `cross_batch_gather`. On a full tie the
# lower run wins, so runs given in input order merge to a stable sort.
#
# The comparator orders a key the way the in-memory run sort
# (`sort_multi.sort_batch_by_keys`) orders it, so a merged run stays sorted:
# INT32 / INT64 / FLOAT32 / FLOAT64 by value alone (floats by
# `sort.sort_key_lt`: NaN above +inf), STRING byte-wise with NULLs first
# ascending and last descending.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_column_kernels.compiler_helpers import copy_batch
from komira_column_kernels.cross_batch_gather import cross_batch_gather

from .sort import sort_key_lt
from .sort_loser_tree import (
    LoserTree,
    LoserTreeComparator,
    LOSER_TREE_SENTINEL,
)


# =============================================================================
# RunCursor -- cursor into one sorted run (1+ batches)
# =============================================================================


struct RunCursor(Movable, Deinitable):
    """A cursor advancing through a sorted run made of one or more batches.

    Owns its batches by value
    so the comparator can read them directly (in-memory runs and spilled-then-
    deserialized runs are stored identically).

    Fields:
        batches: Owned Slab of RecordBatches, in sorted order.
        batch_idx: Current batch position (advances as rows are consumed).
        row_idx: Current row position within the current batch.
    """

    var batches: Slab[RecordBatch]
    var batch_idx: Int
    var row_idx: Int

    def __init__(out self, var batches: Slab[RecordBatch]):
        self.batches = batches^
        self.batch_idx = 0
        self.row_idx = 0

    @always_inline
    def is_exhausted(self) -> Bool:
        return self.batch_idx >= len(self.batches)

    def take_batches(var self) -> Slab[RecordBatch]:
        """Consume this cursor and return its owned batches (the field is
        re-seated with an empty Slab, so the destructor sees a whole value)."""
        var out = self.batches^
        # Re-seat self.batches with a fresh empty array so the implicit
        # destructor at function exit has a valid (drained) field to drop.
        self.batches = Slab[RecordBatch]()
        return out^

    def advance(mut self):
        """Advance to the next row, skipping past empty batches."""
        if self.is_exhausted():
            return
        self.row_idx += 1
        while self.batch_idx < len(self.batches) and self.row_idx >= self.batches[self.batch_idx].num_rows():
            self.batch_idx += 1
            self.row_idx = 0


# =============================================================================
# Per-key comparison: -1 / 0 / +1, ascending; the caller flips it for DESC
# =============================================================================


@always_inline
def _cmp3[dt: DType](a: Scalar[dt], b: Scalar[dt]) -> Int:
    """-1 / 0 / +1 in the `sort_key_lt` order (NaN above +inf, NaNs tied)."""
    if sort_key_lt(a, b):
        return -1
    if sort_key_lt(b, a):
        return 1
    return 0


@always_inline
def _cmp_fixed[dt: DType](
    a_col: Column, a_row: Int, b_col: Column, b_row: Int
) raises -> Int:
    var av = a_col._data.get_typed[Scalar[dt]](a_col._offset + a_row)
    var bv = b_col._data.get_typed[Scalar[dt]](b_col._offset + b_row)
    return _cmp3[dt](av, bv)


@always_inline
def _cmp_string(
    a_col: Column, a_row: Int, b_col: Column, b_row: Int
) raises -> Int:
    """Byte-wise comparison of two STRING (Int32-offset) values; on a shared
    prefix the shorter string is less."""
    if not a_col._offsets or not b_col._offsets:
        raise Error("_cmp_string: missing offsets buffer")
    ref a_off_buf = a_col._offsets.value()
    ref b_off_buf = b_col._offsets.value()
    var ar = a_col._offset + a_row
    var br = b_col._offset + b_row
    var a_s = Int(a_off_buf.get_typed[Int32](ar))
    var a_e = Int(a_off_buf.get_typed[Int32](ar + 1))
    var b_s = Int(b_off_buf.get_typed[Int32](br))
    var b_e = Int(b_off_buf.get_typed[Int32](br + 1))
    var a_len = a_e - a_s
    var b_len = b_e - b_s
    var min_len = a_len if a_len < b_len else b_len
    for i in range(min_len):
        var ab = a_col._data.read_u8_at(a_s + i)
        var bb = b_col._data.read_u8_at(b_s + i)
        if ab < bb:
            return -1
        elif ab > bb:
            return 1
    if a_len < b_len:
        return -1
    elif a_len > b_len:
        return 1
    return 0


@always_inline
def _is_null(col: Column, row: Int) -> Bool:
    if not col._validity:
        return False
    return not col._validity.value().test(col._offset + row)


def _compare_one_key(
    a_col: Column, a_row: Int, b_col: Column, b_row: Int, at: ArrowType
) raises -> Int:
    """Compare two rows on one key column, ascending: -1 / 0 / +1.

    As the in-memory run sort orders the key: a numeric key by its values
    alone (floats by `sort_key_lt`), a STRING key with NULL below every value
    (so NULLs first ascending and, with the sign flipped, last descending).
    """
    if at == ArrowType.INT32:
        return _cmp_fixed[DType.int32](a_col, a_row, b_col, b_row)
    elif at == ArrowType.INT64:
        return _cmp_fixed[DType.int64](a_col, a_row, b_col, b_row)
    elif at == ArrowType.FLOAT32:
        return _cmp_fixed[DType.float32](a_col, a_row, b_col, b_row)
    elif at == ArrowType.FLOAT64:
        return _cmp_fixed[DType.float64](a_col, a_row, b_col, b_row)
    elif at == ArrowType.STRING:
        var a_null = _is_null(a_col, a_row)
        var b_null = _is_null(b_col, b_row)
        if a_null and b_null:
            return 0
        if a_null:
            return -1
        if b_null:
            return 1
        return _cmp_string(a_col, a_row, b_col, b_row)
    else:
        raise Error(
            "ExternalSorter comparator: unsupported sort key type "
            + String(at)
            + " (supported: INT32, INT64, FLOAT32, FLOAT64, STRING)"
        )


# =============================================================================
# RunMergeComparator — LoserTreeComparator over RunCursors
# =============================================================================
#
# Bridges per-stream RunCursor state to the LoserTree contract. Owns the
# per-stream cursor array and all per-key config by value; no raw pointers
# cross a module boundary. All storage is safe (Slab / List) and
# destructed automatically when the comparator goes out of scope.
#
# The comparator is constructed by _k_way_merge, mutated only via its own
# trait methods (LoserTree takes `mut cmp: C`), and destroyed at function
# exit. RunCursor is Movable-only (owns Slab[RecordBatch]), so the
# comparator is also non-Movable by induction; that is fine because
# LoserTreeComparator (since we dropped its Movable bound) and LoserTree's
# generic methods both borrow `mut cmp` without requiring Movable.


struct RunMergeComparator(LoserTreeComparator):
    """LoserTreeComparator that compares the heads of N RunCursors by their
    sort keys.

    Owns all state by value:
      - _cursors: Slab of per-stream RunCursors (advanced via
        advance_cursor() from the merge loop; inspected via the cursor_*
        accessors and is_less()).
      - _key_indices / _descending / _arrow_types: per-key config captured
        once at construction.

    Non-Movable: Slab[RunCursor] is not Copyable and the LoserTree API
    only ever borrows `mut cmp`, never moves it, so Movable would be
    gratuitous (and would force us back to UnsafePointer for the cursors).
    """

    var _cursors: Slab[RunCursor]
    var _num_streams: Int
    var _num_keys: Int
    var _key_indices: List[Int]
    var _descending: List[Bool]
    var _arrow_types: List[UInt8]
    """Per-key ArrowType stored as UInt8 (trivially-copyable)."""

    def __init__(
        out self,
        var cursors: Slab[RunCursor],
        num_streams: Int,
        num_keys: Int,
        var key_indices: List[Int],
        var descending: List[Bool],
        var arrow_types: List[UInt8],
    ):
        self._cursors = cursors^
        self._num_streams = num_streams
        self._num_keys = num_keys
        self._key_indices = key_indices^
        self._descending = descending^
        self._arrow_types = arrow_types^

    # NOTE: No __moveinit__. Slab[RunCursor] is not Movable in any
    # meaningful sense inside a comparator (RunCursor owns MutableArrays),
    # and the LoserTree contract never moves the comparator.

    def is_exhausted(self, i: Int) -> Bool:
        if i < 0 or i >= self._num_streams:
            return True
        return self._cursors[i].is_exhausted()

    def is_less(mut self, a: Int, b: Int) -> Bool:
        # An exhausted stream always loses.
        if a < 0 or a >= self._num_streams:
            return False
        if b < 0 or b >= self._num_streams:
            return True
        if self._cursors[a].is_exhausted():
            return False
        if self._cursors[b].is_exhausted():
            return True

        # Read each cursor's current (batch_idx, row_idx) and compare key by key.
        # is_less is `mut` per the trait but we do not mutate cursors here —
        # only the merge loop advances them via advance_cursor().
        ref ca = self._cursors[a]
        ref cb = self._cursors[b]

        try:
            for k in range(self._num_keys):
                var col_idx = self._key_indices[k]
                var at = ArrowType(self._arrow_types[k])
                var desc = self._descending[k]
                ref a_batch = ca.batches[ca.batch_idx]
                ref b_batch = cb.batches[cb.batch_idx]
                ref a_col = a_batch.column_at(col_idx)
                ref b_col = b_batch.column_at(col_idx)
                var ord = _compare_one_key(a_col, ca.row_idx, b_col, cb.row_idx, at)
                if desc:
                    ord = -ord
                if ord < 0:
                    return True
                elif ord > 0:
                    return False
            # All keys equal — stable: lower stream index wins ("less").
            return a < b
        except e:
            # Comparator can't raise through LoserTree contract; in production
            # this should be unreachable (key types validated by ExternalSorter
            # at construction). On failure, treat as not-less so the merge
            # makes forward progress and surfaces incorrect output rather than
            # a hang. ExternalSorter does pre-flight validation so this path
            # is defensive only.
            return False

    # -------------------------------------------------------------------------
    # Merge-loop accessors (used by _k_way_merge and _materialize_merged)
    # -------------------------------------------------------------------------

    @always_inline
    def advance_cursor(mut self, i: Int):
        """Advance cursor `i` to its next row. Merge-loop entrypoint that
        replaces the pre-refactor `(cursors_buf + i)[].advance()` call."""
        self._cursors[i].advance()

    @always_inline
    def cursor_batch_idx(self, i: Int) -> Int:
        return self._cursors[i].batch_idx

    @always_inline
    def cursor_row_idx(self, i: Int) -> Int:
        return self._cursors[i].row_idx

    @always_inline
    def copy_cursor_batch(self, ci: Int, bi: Int) raises -> RecordBatch:
        """Deep-copy the `bi`-th batch of cursor `ci`: the sources array
        `cross_batch_gather` reads (a borrowed reference through the two
        nested Slabs cannot be returned)."""
        return copy_batch(self._cursors[ci].batches[bi])


# =============================================================================
# k_way_merge_cursors -- the k-way merge of sorted runs (free function)
# =============================================================================
#
# Shared by `ExternalSorter` and by any caller that holds sorted runs and
# knows their key column indices and types (a stage sort's spill path).


def k_way_merge_cursors(
    var cursors_arr: Slab[RunCursor],
    num_keys: Int,
    var key_indices: List[Int],
    var descending: List[Bool],
    var arrow_types: List[UInt8],
    output_batch_size: Int,
) raises -> Slab[RecordBatch]:
    """K-way merge `cursors_arr` (each a sorted run) into output batches.

    The per-key column indices and ArrowTypes are supplied pre-resolved by
    the caller.

    All cursor storage moves into the `RunMergeComparator` (Slab). No
    UnsafePointer crosses a module boundary. Stability: ties broken by lower
    stream index winning (the comparator's `is_less` final clause), so feeding
    runs in a deterministic order reproduces a stable global sort.

    Args:
        cursors_arr: One `RunCursor` per sorted run (consumed).
        num_keys: Number of sort keys.
        key_indices: Per-key column index in the run schema (consumed).
        descending: Per-key direction (consumed).
        arrow_types: Per-key ArrowType as UInt8 (consumed).
        output_batch_size: Rows per merged output batch.
    """
    var num_streams = len(cursors_arr)
    if num_streams == 0:
        return Slab[RecordBatch]()

    # Move each RunCursor into the comparator's own storage: take every slot,
    # then mark the source empty so its destructor drops nothing twice.
    var cursors_fa = Slab[RunCursor].create(num_streams)
    for i in range(num_streams):
        cursors_fa.append(cursors_arr.take_slot_unchecked(i))
    cursors_arr.set_len_unchecked(0)

    var cmp = RunMergeComparator(
        cursors_fa^,
        num_streams,
        num_keys,
        key_indices^,
        descending^,
        arrow_types^,
    )
    var tree = LoserTree(num_streams, cmp)

    var result = Slab[RecordBatch]()
    var row_refs = List[Tuple[Int, Int, Int]]()

    while True:
        var winner = tree.peek_winner()
        if winner == LOSER_TREE_SENTINEL:
            break
        if cmp.is_exhausted(winner):
            break

        row_refs.append((
            winner,
            cmp.cursor_batch_idx(winner),
            cmp.cursor_row_idx(winner),
        ))

        if len(row_refs) >= output_batch_size:
            var b = _materialize_merged_free(cmp, row_refs)
            result.append(b^)
            row_refs = List[Tuple[Int, Int, Int]]()

        cmp.advance_cursor(winner)
        tree.update_winner(cmp)

    if len(row_refs) > 0:
        var b = _materialize_merged_free(cmp, row_refs)
        result.append(b^)

    # Comparator's destructor drops its owned Slab[RunCursor] + per-key Lists.
    return result^


def _materialize_merged_free(
    imm cmp: RunMergeComparator,
    ref row_refs: List[Tuple[Int, Int, Int]],
) raises -> RecordBatch:
    """Materialize one output batch from accumulated `(cursor, batch, row)`
    triples.

    Reads cursor batches via the comparator's safe accessors (no raw
    pointers). `cross_batch_gather` takes `(source_idx, row_idx)` pairs with
    sources keyed by a flat array index, so we dedup `(cursor_idx, batch_idx)`
    pairs into a flat sources array, then map each row_ref into that space.
    """
    var unique_keys_cur = List[Int]()  # cursor_idx
    var unique_keys_bat = List[Int]()  # batch_idx
    var translated = List[Tuple[Int, Int]]()  # (flat_src, row)

    for i in range(len(row_refs)):
        var rr = row_refs[i]
        var ci = rr[0]
        var bi = rr[1]
        var ri = rr[2]
        var found = -1
        for u in range(len(unique_keys_cur)):
            if unique_keys_cur[u] == ci and unique_keys_bat[u] == bi:
                found = u
                break
        if found < 0:
            found = len(unique_keys_cur)
            unique_keys_cur.append(ci)
            unique_keys_bat.append(bi)
        translated.append((found, ri))

    var sources = Slab[RecordBatch]()
    for u in range(len(unique_keys_cur)):
        var ci = unique_keys_cur[u]
        var bi = unique_keys_bat[u]
        sources.append(cmp.copy_cursor_batch(ci, bi))

    return cross_batch_gather(sources, translated)
