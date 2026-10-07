# =============================================================================
# join_index_window_counter -- the STRUCTURAL falsifier for the chunked-join
# index WINDOW
# =============================================================================
#
# WHY THIS EXISTS. A chunked join assemble could hand every chunk its OWN
# `List[Int]` built by slicing -- a full `memcpy` of the chunk's slice of both
# index lists, single-threaded on the driver while the pool workers are
# parked. The copy is not needed: `assemble_join_result_dispatch` BORROWS both
# lists, passes the same list into `emit_gather_column_projected_dispatch` once
# per column in a loop, and that callee declares `read indices: List[Int]`. So
# the chunk driver passes the ORIGINAL list plus an `(index_lo, index_count)`
# window and copies nothing.
#
# THE PROBLEM THIS FILE SOLVES. The window is BYTE-IDENTICAL on output to the
# copy. If a future re-route re-introduces the slice, or threads the window
# but leaves `index_lo` at 0 while still copying, every row of every output
# column is unchanged and every value assertion stays green. A
# correctness-only test cannot see the lever stop applying. So the lever is
# guarded by an OBSERVATION OF THE ALIASING, not by an output comparison --
# the same shape as the `share_as_string` / `copy_bytes = 0` falsifier, and
# for the same reason.
#
# WHAT IS OBSERVED, ONCE PER `assemble_join_result_dispatch` CALL — the frame
# where the two worlds become distinguishable:
#
#   * `calls`         — assembles noted. The denominator.
#   * `windowed`      — assembles whose `index_lo != 0`. A COPYING driver hands
#                       every chunk a list that starts at its own element 0, so
#                       this reads ZERO for it no matter how many chunks it
#                       produced.
#   * `aliased_rows`  — sum of `len(left_indices) - count`, i.e. how many index
#                       elements the assemble could SEE beyond the window it
#                       materializes. A copied per-chunk list is sized EXACTLY
#                       `count`, so this reads ZERO for a copying driver. It is
#                       positive only when the callee is looking at the caller's
#                       whole list — which is what "the copy is gone" MEANS.
#   * `copy_bytes`    — index bytes any caller materialized into a fresh
#                       per-chunk list. The windowed path calls nothing, so this
#                       must read 0; it is the slot a re-introduced copy is
#                       required to declare itself in.
#
# `windowed` and `aliased_rows` are independent and BOTH collapse to 0 the
# moment the driver goes back to copying. Neither is a self-reported constant:
# both are computed from `len(left_indices)` and `index_lo` as they actually
# ARRIVE at the assemble.
#
# COST. At most three relaxed `fetch_add`s -- exactly ONE on the default,
# non-windowed path -- per ASSEMBLE call. Not per column, not per row.
#
# `GlobalCounter` primitive (`global_counter.mojo`) -- no environment read, no
# `unsafe_from_address` laundering, no wildcard-origin field.
# =============================================================================

from komira_counters.global_counter import GlobalCounter


comptime _JIW_CALLS = GlobalCounter[
    "komira_join_assembly_join_index_window_calls"
]
comptime _JIW_WINDOWED = GlobalCounter[
    "komira_join_assembly_join_index_window_windowed"
]
comptime _JIW_ALIASED = GlobalCounter[
    "komira_join_assembly_join_index_window_aliased_rows"
]
comptime _JIW_COPY_BYTES = GlobalCounter[
    "komira_join_assembly_join_index_window_copy_bytes"
]


@always_inline
def join_index_window_note_gather(
    count: Int, index_span: Int, index_base: Int
) raises:
    """Record ONE per-column gather's view of its index list.

    Args:
        count: The number of OUTPUT rows this gather produces (the window
            length).
        index_span: `len(indices)` as the callee sees it — the length of the
            list the caller actually handed over.
        index_base: The window's start offset into that list.

    `index_span - count` is the aliasing observation: it is 0 for a
    per-chunk COPY (a copied list is sized exactly `count`) and positive when
    the callee is reading a window of the caller's whole list."""
    _JIW_CALLS.incr()
    if index_base != 0:
        _JIW_WINDOWED.incr()
    var extra = index_span - count
    if extra > 0:
        _JIW_ALIASED.add(extra)


@always_inline
def join_index_window_note_copy(byte_count: Int) raises:
    """Record index bytes materialized into a FRESH per-chunk list.

    Nothing on the landed path calls this — that is the point. It is the slot a
    re-introduced per-chunk copy is required to declare itself in, so
    `join_index_window_copy_bytes() == 0` stays a meaningful assertion rather
    than a tautology about code that no longer exists."""
    _JIW_COPY_BYTES.add(byte_count)


def join_index_window_calls() raises -> Int:
    """Total per-column gathers noted since the last reset."""
    return _JIW_CALLS.read()


def join_index_window_windowed_calls() raises -> Int:
    """Gathers that arrived with a NON-ZERO `index_base`. Zero for a copying
    driver, whatever its chunk count."""
    return _JIW_WINDOWED.read()


def join_index_window_aliased_rows() raises -> Int:
    """Index elements visible to the callee BEYOND its own output window,
    summed. Zero for a copying driver by construction."""
    return _JIW_ALIASED.read()


def join_index_window_copy_bytes() raises -> Int:
    """Index bytes copied into fresh per-chunk lists. MUST read 0."""
    return _JIW_COPY_BYTES.read()


def reset_join_index_window_counters() raises:
    """Reset all four process-wide counters to 0 (test setup)."""
    _JIW_CALLS.reset()
    _JIW_WINDOWED.reset()
    _JIW_ALIASED.reset()
    _JIW_COPY_BYTES.reset()
