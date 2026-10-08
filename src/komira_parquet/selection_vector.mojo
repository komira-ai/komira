# =============================================================================
# SELECTION INTERVAL — row-level (skip, select) interval for page decode gather
# =============================================================================
#
# The skip/select interval the decode gathers walk. Represents a (skip, select)
# tuple over a BooleanArray mask.
#
# NOTE: this is not an index list of selected rows (`boolean_to_indices` makes
# one). The type here is `SelectionInterval`.
# =============================================================================

from std.bit import count_trailing_zeros

from komira_arrow.boolean_array import BooleanArray


# ---------------------------------------------------------------------------
# SelectionInterval
# ---------------------------------------------------------------------------


@fieldwise_init
struct SelectionInterval(Copyable, Movable):
    """A single (skip, select) interval over a boolean-mask row stream.

    Fields:
        skip:   Number of unselected rows before the selected run.
        select: Number of selected rows in the run.
    """

    var skip: UInt32
    var select: UInt32

    @staticmethod
    def from_bool_mask(
        mask: BooleanArray,
    ) raises -> List[SelectionInterval]:
        """Build a sorted, non-overlapping interval list from a BooleanArray.

        Consecutive `True` bits coalesce into a single `select`; consecutive
        `False` bits accumulate into the following `skip`.
        """
        var out = List[SelectionInterval]()
        boolean_to_intervals(mask, out)
        return out^

    @staticmethod
    def all(num_rows: UInt32) -> List[SelectionInterval]:
        """One interval covering all `num_rows`."""
        var out = List[SelectionInterval]()
        if num_rows > 0:
            out.append(SelectionInterval(UInt32(0), num_rows))
        return out^


# ---------------------------------------------------------------------------
# Free functions
# ---------------------------------------------------------------------------


def intervals_total_selected(
    intervals: Span[SelectionInterval, _],
) -> UInt32:
    """Sum of `select` across all intervals."""
    var total: UInt32 = 0
    for i in range(len(intervals)):
        total += intervals[i].select
    return total


def boolean_to_intervals(
    mask: BooleanArray,
    mut out: List[SelectionInterval],
) raises -> None:
    """Append (skip, select) intervals derived from `mask` to `out`.

    Runs of True rows coalesce into a single interval's `select`; runs of
    False rows accumulate into the following interval's `skip`.

    PERF-CRITICAL: u64 word-walk fast path. Walks the bitmap 64 bits per
    iteration:
      * AllZero word → +64 to pending_skip in one branch
      * AllOne word  → +64 to run_select in one branch
      * Mixed word   → scalar 64-bit walk maintaining run state
    Every scan that builds row-selection intervals from a filter mask runs
    it.
    """
    _boolean_to_intervals_simd(mask, out)


def _boolean_to_intervals_simd(
    mask: BooleanArray,
    mut out: List[SelectionInterval],
) raises -> None:
    """SIMD u64-word-walk implementation of boolean_to_intervals.

    Algorithm:
      1. Process the bitmap in u64 (64-bit) chunks.
         - word == 0 (all-False): if run_select > 0, emit interval and
           reset; then pending_skip += 64.
         - word == 0xFFFFFFFFFFFFFFFF (all-True): run_select += 64
           (current pending_skip is preserved — it'll attach to the
           run when it eventually flushes).
         - mixed word: walk the 64 bits scalar-style. We could ctz-walk
           SET bits but the run-detection loop needs both transitions
           anyway, so the 64-bit scalar walk is simplest and competitive.
      2. Byte tail: 0..7 leftover bytes, each handled with the same
         8-bit scalar walk.
      3. Bit tail: trailing partial byte (length & 7 bits), scalar walk.
      4. After the loop, flush any in-flight run.

    Postcondition: byte-identical to the previous scalar
    `for i in range(n): mask.get(i)` reference.
    """
    var n = mask.length
    var pending_skip: UInt32 = 0
    var run_select: UInt32 = 0

    if n <= 0:
        return

    var bm_view = mask.data.buffer.view_ro()
    var full_bytes = n >> 3

    # ------ Fast loop: 8 bytes (64 bits) at a time ------
    var u64_end = full_bytes >> 3
    var u64_byte_end = u64_end << 3

    var u64_idx = 0
    while u64_idx < u64_end:
        var byte_off = u64_idx << 3
        var word = bm_view.read_u64_le_at(byte_off)
        if word == UInt64(0):
            # Fast path 1: 64 zero bits.
            # If we have an in-flight selected run, flush it.
            if run_select > 0:
                out.append(SelectionInterval(pending_skip, run_select))
                pending_skip = 0
                run_select = 0
            pending_skip += UInt32(64)
            u64_idx += 1
            continue
        if word == UInt64(0xFFFFFFFFFFFFFFFF):
            # Fast path 2: 64 set bits — extend the in-flight run.
            run_select += UInt32(64)
            u64_idx += 1
            continue
        # Mixed word: scalar 64-bit walk maintaining run_select / pending_skip.
        for bit in range(64):
            var b = (word >> UInt64(bit)) & UInt64(1)
            if b == UInt64(1):
                run_select += UInt32(1)
            else:
                if run_select > 0:
                    out.append(
                        SelectionInterval(pending_skip, run_select)
                    )
                    pending_skip = UInt32(0)
                    run_select = UInt32(0)
                pending_skip += UInt32(1)
        u64_idx += 1

    # ------ Byte tail: 0..7 bytes past the last full u64 ------
    for byte_idx in range(u64_byte_end, full_bytes):
        var byte_val = bm_view.read_u8_at(byte_idx)
        if byte_val == UInt8(0):
            if run_select > 0:
                out.append(SelectionInterval(pending_skip, run_select))
                pending_skip = 0
                run_select = 0
            pending_skip += UInt32(8)
            continue
        if byte_val == UInt8(0xFF):
            run_select += UInt32(8)
            continue
        for bit in range(8):
            var b = (byte_val >> UInt8(bit)) & UInt8(1)
            if b == UInt8(1):
                run_select += UInt32(1)
            else:
                if run_select > 0:
                    out.append(
                        SelectionInterval(pending_skip, run_select)
                    )
                    pending_skip = UInt32(0)
                    run_select = UInt32(0)
                pending_skip += UInt32(1)

    # ------ Bit tail: trailing partial byte (length & 7) ------
    var remaining = n & 7
    if remaining > 0:
        var byte_val = bm_view.read_u8_at(full_bytes)
        for bit in range(remaining):
            var b = (byte_val >> UInt8(bit)) & UInt8(1)
            if b == UInt8(1):
                run_select += UInt32(1)
            else:
                if run_select > 0:
                    out.append(
                        SelectionInterval(pending_skip, run_select)
                    )
                    pending_skip = UInt32(0)
                    run_select = UInt32(0)
                pending_skip += UInt32(1)

    # ------ Final flush ------
    if run_select > 0:
        out.append(SelectionInterval(pending_skip, run_select))


def _boolean_to_intervals_scalar(
    mask: BooleanArray,
    mut out: List[SelectionInterval],
) raises -> None:
    """Scalar reference implementation of boolean_to_intervals.

    Preserved as the correctness oracle for `_boolean_to_intervals_simd`.
    Tests assert SIMD == scalar byte-for-byte across selectivity, length,
    and alignment edge cases.
    """
    var n = mask.length
    var pending_skip: UInt32 = 0
    var run_select: UInt32 = 0

    for i in range(n):
        var bit = mask.get(i)
        if bit:
            run_select += 1
        else:
            if run_select > 0:
                out.append(SelectionInterval(pending_skip, run_select))
                pending_skip = 0
                run_select = 0
            pending_skip += 1

    if run_select > 0:
        out.append(SelectionInterval(pending_skip, run_select))


def boolean_to_indices(mask: BooleanArray) raises -> List[UInt32]:
    """Fallback: expand mask into an index list of selected positions."""
    var out = List[UInt32]()
    var n = mask.length
    for i in range(n):
        if mask.get(i):
            out.append(UInt32(i))
    return out^
