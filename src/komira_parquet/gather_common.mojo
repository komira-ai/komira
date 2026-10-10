# =============================================================================
# Selection gather — common types and helpers shared across gather variants
# =============================================================================
#
# Kept apart from the gathers so that `gather_byte_array.mojo`,
# `gather_dict.mojo` and their callers share one `_PageExtent`,
# `_PageDefLevels`, and `_build_value_index` without importing one another.
#
# These types are intentionally minimal and have no I/O dependencies:
#   * `_PageExtent`   — parallel-array metadata for a decompressed page
#                       (num_values + encoding).
#   * `_PageDefLevels` — per-page def-level row vector + cached non-null count.
#   * `_build_value_index` — exclusive-running-rank table over u8 def levels.
#   * `_check_num_selected` — the gathers' up-front check that the selection
#                       intervals select exactly `num_selected` rows.
# =============================================================================


# ---------------------------------------------------------------------------
# _PageExtent — parallel-array metadata for a decompressed page
# ---------------------------------------------------------------------------


from komira_parquet_api.types import Encoding

from .selection_vector import SelectionInterval


@fieldwise_init
struct _PageExtent(Copyable, Movable, ImplicitlyCopyable):
    """Metadata for one entry in the parallel `Slab[SharedAlignedBuffer]`
    of decompressed page buffers.

    Fields:
        num_values: Number of data rows in this page (header.num_values).
        encoding:   PLAIN / RLE_DICTIONARY / PLAIN_DICTIONARY / DELTA_*.
            PLAIN pages go to the plain gathers, RLE_DICTIONARY and
            PLAIN_DICTIONARY pages to the dictionary gathers.
    """

    var num_values: Int
    var encoding: Encoding


# ---------------------------------------------------------------------------
# _PageDefLevels — parallel-array def-level metadata for one nullable page
# ---------------------------------------------------------------------------


@fieldwise_init
struct _PageDefLevels(Movable):
    """Per-page definition level record for the nullable gather path.

    Fields:
        defs: Flat u8 row vector, length == page.num_values. 0 = null,
            1 = non-null. Produced by `decode_def_levels_u8`.
        num_non_null: Count of positions with `defs[r] != 0`. Equals the
            number of entries in the PLAIN value stream for this page.
    """

    var defs: List[UInt8]
    var num_non_null: Int


# ---------------------------------------------------------------------------
# _build_value_index — running rank table for value-stream lookup
# ---------------------------------------------------------------------------


def _build_value_index(def_levels: Span[UInt8, _]) -> List[UInt32]:
    """Build a running rank table: `value_index[r] = sum(def_levels[0..r])`.

    Convention: exclusive running sum — `value_index[r]` is the rank
    BEFORE counting position r. i.e. if def_levels = [1,0,1,1], then
    value_index = [0,1,1,2].

    Args:
        def_levels: Per-row u8 def-level vector from
            `decode_def_levels_u8`. Length equals page.num_values.

    Returns:
        List[UInt32] of the same length as `def_levels`. UInt32 is wide
        enough for any Parquet page (max 2^31 rows).
    """
    var n = len(def_levels)
    var out = List[UInt32](capacity=n)
    var running: UInt32 = 0
    for i in range(n):
        out.append(running)
        if def_levels[i] != 0:
            running += 1
    return out^


# ---------------------------------------------------------------------------
# _check_num_selected — the intervals select exactly `num_selected` rows
# ---------------------------------------------------------------------------


def _check_num_selected(
    who: String,
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises:
    """Refuse a `num_selected` that is not the intervals' total `select`.

    Every gather sizes its output buffers from `num_selected` and writes one
    slot per selected row, so a total past it would write past the buffers.
    The sum is taken in `Int`, so intervals whose UInt32 `select` values add
    up past 2^32 cannot wrap to a small total.
    """
    var total = 0
    for i in range(len(intervals)):
        total += Int(intervals[i].select)
    if total != num_selected:
        raise Error(
            who
            + ": the selection intervals select "
            + String(total)
            + " rows, not num_selected = "
            + String(num_selected)
        )
