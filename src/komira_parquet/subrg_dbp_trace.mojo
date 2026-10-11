# =============================================================================
# subrg_dbp_trace — the fire counters of the resumable DELTA_BINARY_PACKED arm
#                   of `ResumableColumnCursor`
# =============================================================================
#
# A flat (non-dictionary) INT32 or INT64 column chunk whose data pages are
# DELTA_BINARY_PACKED is decoded by the sub-row-group cursor a chunk of rows at
# a time (`subrg_column_cursor`). These counters say whether that arm ran and
# how much it did, so a run that measures no change can tell "the arm never
# armed" from "the arm armed and changed nothing":
#
#   * `open-admit`   chunks admitted at `try_open` because their first data
#                    page is DELTA_BINARY_PACKED. Zero means the file is not
#                    DBP-encoded or no cursor opened.
#   * `open-decline` flat chunks refused at `try_open` because their first data
#                    page is neither PLAIN nor DELTA_BINARY_PACKED (or not a V1
#                    DATA_PAGE).
#   * `pages`        DBP data pages armed (`DeltaDecoder.begin_resumable`).
#   * `values`       values returned by the DBP fill, added once per fill call,
#                    never per value; `values / pages` is the mean page size.
#   * `stall`        fills that made no progress while the page still declared
#                    values (a malformed page). Zero on a well-formed file.
#
# The counters are always on: one relaxed atomic add per page or per fill call.
# Only the print is gated, and the gate is SET, never read from the
# environment: `set_subrg_dbp_trace_enabled(True)` turns on the one-shot
# `ARMED` line (`dbp_note_armed`), the running count line printed when the page
# count reaches a power of two, and `dbp_trace_dump`. A program that wants a
# switch maps its own flag to the setter.
#
# Mechanism: the name-keyed, process-global `_Global` slot, as in
# `scan_copy_trace`. No address rebuilt from an integer, no pointer in a public
# signature.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_dbp_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): one counter or latch per process,
    initialised to 0."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init. `Atomic` is not movable by value, so its
    # scalar is written in place before `OwnedPointer` takes ownership; the raw
    # pointer never leaves this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_OPEN_ADMIT = _Global[
    "komira_parquet_subrg_dbp_open_admit", _init_dbp_slot
]
comptime _C_OPEN_DECLINE = _Global[
    "komira_parquet_subrg_dbp_open_decline", _init_dbp_slot
]
comptime _C_PAGES = _Global["komira_parquet_subrg_dbp_pages", _init_dbp_slot]
comptime _C_VALUES = _Global["komira_parquet_subrg_dbp_values", _init_dbp_slot]
comptime _C_STALL = _Global["komira_parquet_subrg_dbp_stall", _init_dbp_slot]

# The print gate: 0 (no setter ran: the default, off), 1 on, 2 off.
comptime _G_TRACE = _Global[
    "komira_parquet_gate_subrg_dbp_trace", _init_dbp_slot
]
# One-shot latch so N workers print the `ARMED` line once.
comptime _G_ARMED_ONCE = _Global[
    "komira_parquet_subrg_dbp_armed_once", _init_dbp_slot
]

comptime _GATE_ON: Int64 = 1
comptime _GATE_OFF: Int64 = 2


# SAFETY (every `get_or_create_ptr` below): the pointer targets runtime-managed
# process-lifetime storage; its type is the stdlib `_Global` API's own and it
# is dereferenced in place, never returned.


@always_inline
def incr_dbp_open_admit() raises:
    """Count one chunk admitted as flat DELTA_BINARY_PACKED at `try_open`."""
    _ = _C_OPEN_ADMIT.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_dbp_open_decline() raises:
    """Count one flat chunk refused at `try_open` for its page encoding."""
    _ = _C_OPEN_DECLINE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def dbp_page_is_milestone(n: Int) -> Bool:
    """True when the running page count `n` is a power of two (1, 2, 4, ...).

    A power of two always reports the first page and then costs about
    log2(pages) lines at any scale; a fixed modulus either floods a long run
    or never fires on a short one."""
    return n > 0 and (n & (n - 1)) == 0


def incr_dbp_page() raises:
    """Count one DBP data page armed and, when the count reaches a power of
    two, print the running count line (`dbp_trace_dump("page-milestone")`).

    The line is printed from the cursor's own page open, so no caller, sink or
    early exit can suppress it."""
    var prev = _C_PAGES.get_or_create_ptr()[][].fetch_add(Int64(1))
    if dbp_page_is_milestone(Int(prev) + 1):
        dbp_trace_dump(StaticString("page-milestone"))


@always_inline
def add_dbp_values(n: Int) raises:
    """Add the `n` values one DBP fill call returned."""
    _ = _C_VALUES.get_or_create_ptr()[][].fetch_add(Int64(n))


@always_inline
def incr_dbp_stall() raises:
    """Count one DBP fill that made no progress with values still declared."""
    _ = _C_STALL.get_or_create_ptr()[][].fetch_add(Int64(1))


def dbp_open_admit_count() raises -> Int:
    """Chunks admitted as flat DBP, process-wide."""
    return Int(_C_OPEN_ADMIT.get_or_create_ptr()[][].load())


def dbp_open_decline_count() raises -> Int:
    """Flat chunks refused for their page encoding, process-wide."""
    return Int(_C_OPEN_DECLINE.get_or_create_ptr()[][].load())


def dbp_page_count() raises -> Int:
    """DBP data pages armed, process-wide."""
    return Int(_C_PAGES.get_or_create_ptr()[][].load())


def dbp_value_count() raises -> Int:
    """Values returned by the DBP fill, process-wide."""
    return Int(_C_VALUES.get_or_create_ptr()[][].load())


def dbp_stall_count() raises -> Int:
    """No-progress DBP fills, process-wide."""
    return Int(_C_STALL.get_or_create_ptr()[][].load())


def reset_dbp_counts() raises:
    """Zero every counter and the one-shot `ARMED` latch."""
    _C_OPEN_ADMIT.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_OPEN_DECLINE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_PAGES.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_VALUES.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_STALL.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _G_ARMED_ONCE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


@always_inline
def subrg_dbp_trace_enabled() raises -> Bool:
    """Whether the DBP arm's lines print. DEFAULT OFF."""
    return _G_TRACE.get_or_create_ptr()[][].load() == _GATE_ON


def set_subrg_dbp_trace_enabled(on: Bool) raises:
    """Turn the DBP arm's lines on or off for the process."""
    _G_TRACE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def dbp_note_armed(elem_width: Int) raises:
    """Print `[subrg-dbp] ARMED` the first time a DBP chunk is admitted, from
    whichever worker gets there first; later calls are silent.

    Printed at chunk open, so a run that fails before any worker finishes
    still says whether the arm armed."""
    if not subrg_dbp_trace_enabled():
        return
    # `fetch_add` returning 0 picks the single winner across workers.
    var prev = _G_ARMED_ONCE.get_or_create_ptr()[][].fetch_add(Int64(1))
    if prev != Int64(0):
        return
    print(
        "[subrg-dbp] ARMED: flat DELTA_BINARY_PACKED column admitted at"
        " try_open; elem_width=",
        elem_width,
        sep="",
    )


def dbp_trace_dump(site: StaticString) raises:
    """Print the counts, tagged with the emitting `site`, when the trace is on.

    The counts are cumulative over the process, so with several scans per
    process the last line is the total."""
    if not subrg_dbp_trace_enabled():
        return
    print(
        "[subrg-dbp] at=", site,
        " open-admit=", dbp_open_admit_count(),
        " open-decline=", dbp_open_decline_count(),
        " pages=", dbp_page_count(),
        " values=", dbp_value_count(),
        " stall=", dbp_stall_count(),
        sep="",
    )
