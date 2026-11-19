# =============================================================================
# row_sort_perm.mojo — shared stable index-permutation sort for the row family
# =============================================================================
#
# The WITHIN-ROW-FAMILY shared sort driver. The comparator is NOT shared
# across orientations (column `SortBuffer` vs the row buffers): the column comparator is comptime-`*Keys`-
# parametric over typed SoA `List[Scalar[dt]]` (`SortKeyColumn.compare_at`),
# while the row comparators are runtime-DType-ladder reads over a byte-arena
# `RowBlock`. Bridging them would force a runtime value into the column's
# comptime `*Keys` param slot (impossible) OR a fn-ptr per-cell read through
# the sort hot loop (banned — no wildcard / fn-ptr in the comparator hot loop).
# This is the same structurally-disjoint verdict as for the hash-table
# substrate.
#
# What IS genuinely duplicated and safe to share: the STABLE SORT OVER AN
# INDEX PERMUTATION `List[Int]`. All row sort buffers run the EXACT same driver
# (iota → stable sort by `compare`), differing ONLY in the per-pair comparison:
#   * RowSortBufferRuntime.sort()              (runtime DType-ladder compare)
#   * RowSortBufferRuntime._compute_sorted_perm()  (same, read-only variant)
#   * RowSortBuffer.finalize_sort()            (arrow_row byte-lex compare)
# This module lifts the driver into ONE comptime-parametric helper; the per-pair
# comparison stays on the concrete buffer (the `RowPermComparator` conformer),
# monomorphized at compile time — NO runtime fn-ptr, NO wildcard origin, NO
# indirection in the hot loop. The comptime `C: RowPermComparator` specialization
# compiles the `comparator.compare` call to the conformer's own cell-read body
# (the SortKeyColumn / CellSource trait-method precedent).
#
# Algorithm: an O(n log n) STABLE bottom-up merge sort (was a literal O(n^2)
# insertion sort, which made the row SORT breaker quadratic — a single sort of
# the 6M-row `csv-row-sort-lineitem` bench was ~1.8e13 comparisons). Leaf runs
# of <= `_MERGE_INSERTION_CUTOFF` rows are stable-insertion-sorted; runs are
# then merged pairwise, taking the LEFT element on a tie so equal-key rows keep
# input order (stability — byte-identical to the prior insertion-sort driver).
#
# Encapsulation invariants:
#   * ZERO UnsafePointer in any signature — the comparator conformer reads
#     cells via its own encapsulated `RowBlock` accessors.
#   * ZERO wildcard origin — the comparator is passed by borrow (`read`); its
#     `compare` borrows `self` (concrete origin).
#   * ZERO fn-ptr dispatch — `C: RowPermComparator` is comptime-monomorphized.
#   * ZERO unsafe_from_address / ArcPointer / take_pointee / additive API.
# =============================================================================


trait RowPermComparator(Deinitable):
    """3-way row comparator for the stable index-permutation sort.

    Conformers own their row storage (a `RowBlock` + key spec, or a pre-encoded
    byte-lex key list) and expose a single `compare(row_a, row_b)` that returns
    the FINAL ordering result (per-key direction already applied):

        -1  row_a sorts strictly before row_b
         0  row_a == row_b on all sort keys (tie — stable order preserved)
        +1  row_a sorts strictly after row_b

    The sort driver below shifts on `compare(a, b) > 0`, so a `0` return leaves
    equal-key rows in input order (stable). Conformers in tree:
      * `RowSortBufferRuntime` (runtime DType-ladder cell compare).
      * `RowSortBuffer` (arrow_row byte-lex compare on pre-encoded keys).
    """

    def compare(self, row_a: Int, row_b: Int) raises -> Int:
        """3-way compare of row `row_a` vs row `row_b`; per-key direction
        already applied. Returns -1 / 0 / +1."""
        ...


# Below this row count, the bottom-up merge sort falls back to a stable
# insertion sort for the leaf runs: insertion sort has lower constant factor
# and better cache behavior on tiny runs, and is itself stable (the strict
# `> 0` shift condition leaves equal-key elements in input order). 32 is the
# standard cutoff used by introspective/merge hybrids (e.g. libstdc++ / Timsort
# min-run is in the 32-64 range).
comptime _MERGE_INSERTION_CUTOFF: Int = 32


@always_inline
def _insertion_sort_run[
    C: RowPermComparator
](mut perm: List[Int], lo: Int, hi: Int, comparator: C) raises:
    """Stable insertion sort of `perm[lo:hi]` in place (leaf run of the merge
    sort). `[lo, hi)` half-open. Stable: shift only on `compare > 0`, so equal-
    key elements never cross each other."""
    for i in range(lo + 1, hi):
        var cur = perm[i]
        var j = i - 1
        while j >= lo and comparator.compare(perm[j], cur) > 0:
            perm[j + 1] = perm[j]
            j = j - 1
        perm[j + 1] = cur


def stable_insertion_sort_perm[
    C: RowPermComparator
](n: Int, comparator: C) raises -> List[Int]:
    """Return a fresh STABLE index permutation of `[0, n)` ordered by
    `comparator.compare` — an O(n log n) bottom-up merge sort.

    History: this driver was a literal O(n^2) insertion sort, which made the
    row SORT breaker quadratic in row count (a single sort of the 6M-row
    `csv-row-sort-lineitem` bench was ~1.8e13 comparisons). It is now a stable
    bottom-up (iterative) merge sort over the index permutation:
      * Leaf runs of <= `_MERGE_INSERTION_CUTOFF` rows are stable-insertion-
        sorted in place (low constant factor on tiny runs).
      * Adjacent runs are merged pairwise into a scratch buffer; on a TIE
        (`compare == 0`) the merge takes the LEFT element first, so the run
        that occupied the earlier input positions stays earlier — preserving
        input order on equal keys (stability). The two halves swap ping-pong
        between `perm` and `scratch`, so the result lands back in `perm` after
        an even number of passes (the final copy below normalizes either case).

    Stability is byte-identical to the prior insertion-sort driver: both keep
    equal-key rows in input order. The name is retained so all call sites
    (`RowSortBufferRuntime.sort` / `_compute_sorted_perm`,
    `RowSortBuffer.finalize_sort`) are unchanged — the trait surface and the
    comptime-monomorphized `comparator.compare` (no runtime fn-ptr, no
    indirection in the hot loop) are unchanged; only the driver's complexity
    class moved from O(n^2) to O(n log n).

    Args:
        n: Number of rows (the permutation domain `[0, n)`).
        comparator: The 3-way row comparator conformer (borrowed).

    Returns:
        A `List[Int]` of length `n`: the stable-sorted index permutation.
    """
    var perm = List[Int](capacity=n)
    for i in range(n):
        perm.append(i)
    if n <= 1:
        return perm^

    # Pass 1: stable-insertion-sort each leaf run of `_MERGE_INSERTION_CUTOFF`.
    var run = _MERGE_INSERTION_CUTOFF
    var s = 0
    while s < n:
        var e = s + run
        if e > n:
            e = n
        _insertion_sort_run(perm, s, e, comparator)
        s = e

    # Bottom-up merge passes: double the run width until it covers `n`.
    # Ping-pong between `perm` (src) and `scratch` (dst); after each pass the
    # roles swap. `scratch` is a fresh list of length `n` reused across passes.
    var scratch = List[Int](capacity=n)
    for _ in range(n):
        scratch.append(0)

    # `src_is_perm` tracks which buffer currently holds the sorted-so-far runs.
    var src_is_perm = True
    while run < n:
        # Merge adjacent [lo, mid) + [mid, hi) runs from src into dst.
        var lo = 0
        while lo < n:
            var mid = lo + run
            if mid > n:
                mid = n
            var hi = lo + 2 * run
            if hi > n:
                hi = n
            if src_is_perm:
                _merge_runs(perm, scratch, lo, mid, hi, comparator)
            else:
                _merge_runs(scratch, perm, lo, mid, hi, comparator)
            lo = hi
        src_is_perm = not src_is_perm
        run = run * 2

    # If the last sorted buffer is `scratch`, copy it back into `perm`.
    if not src_is_perm:
        for i in range(n):
            perm[i] = scratch[i]
    return perm^


@always_inline
def _merge_runs[
    C: RowPermComparator
](
    imm src: List[Int],
    mut dst: List[Int],
    lo: Int,
    mid: Int,
    hi: Int,
    comparator: C,
) raises:
    """Stable merge of `src[lo:mid)` and `src[mid:hi)` into `dst[lo:hi)`.

    On a TIE (`compare(src[i], src[j]) == 0`) the LEFT element (`src[i]`, the
    earlier run) is emitted first, so equal-key elements retain input order
    (stability). `compare > 0` means left sorts AFTER right, so right is taken;
    otherwise (left sorts before OR ties) left is taken."""
    var i = lo
    var j = mid
    var k = lo
    while i < mid and j < hi:
        # Take LEFT unless it strictly sorts after RIGHT (stable on tie).
        if comparator.compare(src[i], src[j]) > 0:
            dst[k] = src[j]
            j += 1
        else:
            dst[k] = src[i]
            i += 1
        k += 1
    while i < mid:
        dst[k] = src[i]
        i += 1
        k += 1
    while j < hi:
        dst[k] = src[j]
        j += 1
        k += 1
