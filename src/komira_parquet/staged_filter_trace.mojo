# =============================================================================
# staged_filter_trace — the staged filter decode's gate and arming counters
# =============================================================================
#
# The staged filter decode (in the scan package) decodes a pushed filter's
# columns conjunct by conjunct: the first conjunct's columns in full, each
# later column only for the rows still alive. These are its gate and its
# counters. They live in this leaf module, apart from the decode itself, so
# the trace dump in `scan_copy_trace` can print them without importing the
# scan package.
#
# ⚠ THE OBSERVABLE IS A COUNT, NOT A FLAG. `rg` row groups took the staged
# decode, `DECLINED` of them stopped after a non-selective lead (at least half
# kept) and finished one-shot; `sel` of their deferred-column decodes were
# row-selective (`rows-sel` values against `rows-full`), `GATHER` fell back to
# full decode + gather. `rg=0` on a route expected to arm is a wrong arm map
# or an ineligible predicate, not a null.
#
# The gate defaults ON and is set with `set_staged_filter_enabled`; nothing
# here reads the environment.
#
# Mechanism: name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot. No address rebuilt
# from an integer, no UnsafePointer in any public signature.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc

def _init_staged_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn: one zeroed Atomic per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init, concrete origin from `alloc`; the scalar is
    # initialised in place before `OwnedPointer` takes ownership and the raw
    # pointer never leaves this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_SF_RG = _Global["komira_parquet_staged_filter_rg", _init_staged_slot]
comptime _C_SF_SEL = _Global["komira_parquet_staged_filter_sel", _init_staged_slot]
comptime _C_SF_GATHER = _Global[
    "komira_parquet_staged_filter_gather", _init_staged_slot
]
comptime _C_SF_ROWS_SEL = _Global[
    "komira_parquet_staged_filter_rows_sel", _init_staged_slot
]
comptime _C_SF_ROWS_FULL = _Global[
    "komira_parquet_staged_filter_rows_full", _init_staged_slot
]
comptime _C_SF_DECLINED = _Global[
    "komira_parquet_staged_filter_declined", _init_staged_slot
]
comptime _G_SF = _Global["komira_parquet_gate_staged_filter", _init_staged_slot]


def staged_filter_enabled() raises -> Bool:
    """The staged filter gate, DEFAULT ON. `set_staged_filter_enabled(False)`
    is the kill switch and the A/B arm. A relaxed atomic load."""
    # SAFETY: `_Global.get_or_create_ptr` returns the process-global slot; the
    # pointer never escapes this function.
    var p = _G_SF.get_or_create_ptr()
    var cur = p[][].load()
    return cur != 2


def set_staged_filter_enabled(on: Bool) raises:
    """Turn the staged filter decode on or off for the process. A program
    maps its own flag to this setter."""
    # SAFETY: see `staged_filter_enabled`.
    _G_SF.get_or_create_ptr()[][].store(Int64(1) if on else Int64(2))


def reset_staged_filter_gate() raises:
    """Drop the gate back to its default (ON), as if no setter had run."""
    # SAFETY: see `staged_filter_enabled`.
    _G_SF.get_or_create_ptr()[][].store(Int64(0))


def incr_staged_filter_rg() raises:
    """One row group whose filter took the staged decode."""
    # SAFETY: see `staged_filter_enabled`.
    _ = _C_SF_RG.get_or_create_ptr()[][].fetch_add(Int64(1))


def incr_staged_filter_sel(rows_decoded: Int, rows_full: Int) raises:
    """One deferred-column decode served ROW-SELECTIVELY: `rows_decoded`
    values materialised where the full decode would have made `rows_full`."""
    # SAFETY: see `staged_filter_enabled`.
    _ = _C_SF_SEL.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _C_SF_ROWS_SEL.get_or_create_ptr()[][].fetch_add(Int64(rows_decoded))
    _ = _C_SF_ROWS_FULL.get_or_create_ptr()[][].fetch_add(Int64(rows_full))


def incr_staged_filter_gather() raises:
    """One deferred-column decode that fell back to full decode + gather (a
    fixed-width column under the default mode, or a declined shape)."""
    # SAFETY: see `staged_filter_enabled`.
    _ = _C_SF_GATHER.get_or_create_ptr()[][].fetch_add(Int64(1))


def incr_staged_filter_declined() raises:
    """One row group whose LEAD kept at least half its rows: staging stopped
    and the one-shot route finished it (`staged_handoff`)."""
    # SAFETY: see `staged_filter_enabled`.
    _ = _C_SF_DECLINED.get_or_create_ptr()[][].fetch_add(Int64(1))


def staged_filter_declined_count() raises -> Int:
    # SAFETY: see `staged_filter_enabled`.
    return Int(_C_SF_DECLINED.get_or_create_ptr()[][].load())


def staged_filter_rg_count() raises -> Int:
    # SAFETY: see `staged_filter_enabled`.
    return Int(_C_SF_RG.get_or_create_ptr()[][].load())


def staged_filter_sel_count() raises -> Int:
    # SAFETY: see `staged_filter_enabled`.
    return Int(_C_SF_SEL.get_or_create_ptr()[][].load())


def staged_filter_gather_count() raises -> Int:
    # SAFETY: see `staged_filter_enabled`.
    return Int(_C_SF_GATHER.get_or_create_ptr()[][].load())


def staged_filter_rows_sel() raises -> Int:
    # SAFETY: see `staged_filter_enabled`.
    return Int(_C_SF_ROWS_SEL.get_or_create_ptr()[][].load())


def staged_filter_rows_full() raises -> Int:
    # SAFETY: see `staged_filter_enabled`.
    return Int(_C_SF_ROWS_FULL.get_or_create_ptr()[][].load())


def reset_staged_filter_counts() raises:
    """Zero every counter (tests asserting a per-scan delta)."""
    # SAFETY: see `staged_filter_enabled`.
    _C_SF_RG.get_or_create_ptr()[][].store(Int64(0))
    _C_SF_SEL.get_or_create_ptr()[][].store(Int64(0))
    _C_SF_GATHER.get_or_create_ptr()[][].store(Int64(0))
    _C_SF_ROWS_SEL.get_or_create_ptr()[][].store(Int64(0))
    _C_SF_ROWS_FULL.get_or_create_ptr()[][].store(Int64(0))
    _C_SF_DECLINED.get_or_create_ptr()[][].store(Int64(0))
