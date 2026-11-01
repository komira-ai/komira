# =============================================================================
# cursor_grain_split_emit — the cursor-grain route honours `morsel_rows`
# =============================================================================
#
# Every whole-row-group emit of the morsel source cuts its decoded batch into
# `morsel_rows`-sized sub-morsels (`_split_and_stash_first`). The cursor-grain
# route emits one decode grain at a time; with the grain derived from the
# morsel size it never exceeds `morsel_rows`, but a grain set explicitly can.
# This module makes that route cut its grains too, so the morsel geometry the
# executor sees does not depend on the decode grain.
#
# Sub-slot numbering: the collect sink stable-sorts morsels by
# `(partition_id, origin_hint)` to restore file order. A grain's sub-morsels
# take slots from `grain_idx * subs_per_grain`, where `subs_per_grain =
# ceil(grain_rows / morsel_rows)` is fixed per source: every grain but the
# last has exactly `grain_rows` rows, so the per-grain blocks are disjoint and
# increase in file order (the last grain may leave a gap, which a stable sort
# ignores).
#
# Gate: `cursor_grain_split_enabled`, default ON, set with
# `set_cursor_grain_split_enabled`. Counters (always on, a few relaxed adds
# per grain): grains split, grains emitted whole, emitted rows and morsels; a
# split count of 0 with a whole count of 0 means the route never emitted.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


@always_inline
def cursor_grain_sub_count(n_rows: Int, morsel_rows: Int) -> Int:
    """How many sub-morsels a batch of `n_rows` is cut into:
    `ceil(n_rows / morsel_rows)`, and 1 when no split is owed (a
    non-positive `morsel_rows` means none is configured)."""
    if morsel_rows <= 0 or n_rows <= morsel_rows:
        return 1
    return (n_rows + morsel_rows - 1) // morsel_rows


def _init_split_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is the one fresh allocation above; the scalar is written
    # in place before `OwnedPointer` takes ownership, and `raw` never leaves
    # this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_SPLIT_GRAINS = _Global["komira_parquet_cursor_grain_split_grains", _init_split_slot]
comptime _C_NOSPLIT_GRAINS = _Global["komira_parquet_cursor_grain_nosplit_grains", _init_split_slot]
comptime _C_EMIT_ROWS = _Global["komira_parquet_cursor_grain_emit_rows", _init_split_slot]
comptime _C_EMIT_MORSELS = _Global["komira_parquet_cursor_grain_emit_morsels", _init_split_slot]
comptime _G_SPLIT_GATE = _Global["komira_parquet_gate_cursor_grain_split", _init_split_slot]

comptime _GATE_OFF: Int64 = 2


@always_inline
def note_cursor_grain_split(grain_rows: Int, n_sub: Int) raises:
    """One grain cut into `n_sub` sub-morsels."""
    _ = _C_SPLIT_GRAINS.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _C_EMIT_ROWS.get_or_create_ptr()[][].fetch_add(Int64(grain_rows))
    _ = _C_EMIT_MORSELS.get_or_create_ptr()[][].fetch_add(Int64(n_sub))


@always_inline
def note_cursor_grain_nosplit(grain_rows: Int) raises:
    """One grain emitted whole (it fitted `morsel_rows`, or the gate is off)."""
    _ = _C_NOSPLIT_GRAINS.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _C_EMIT_ROWS.get_or_create_ptr()[][].fetch_add(Int64(grain_rows))
    _ = _C_EMIT_MORSELS.get_or_create_ptr()[][].fetch_add(Int64(1))


def cursor_grain_split_grains() raises -> Int:
    """Grains cut into sub-morsels."""
    return Int(_C_SPLIT_GRAINS.get_or_create_ptr()[][].load())


def cursor_grain_nosplit_grains() raises -> Int:
    """Grains emitted whole."""
    return Int(_C_NOSPLIT_GRAINS.get_or_create_ptr()[][].load())


def cursor_grain_emit_morsels() raises -> Int:
    """Morsels the cursor route handed downstream, sub-morsels included."""
    return Int(_C_EMIT_MORSELS.get_or_create_ptr()[][].load())


def cursor_grain_emit_rows() raises -> Int:
    """Rows the cursor route handed downstream."""
    return Int(_C_EMIT_ROWS.get_or_create_ptr()[][].load())


def cursor_grain_observed_emit() raises -> Int:
    """Rows per emitted morsel (0 when the route never emitted)."""
    var morsels = cursor_grain_emit_morsels()
    if morsels == 0:
        return 0
    return cursor_grain_emit_rows() // morsels


def reset_cursor_grain_split_counts() raises:
    """Zero the four counters (a test's setup)."""
    _C_SPLIT_GRAINS.get_or_create_ptr()[][].store(Int64(0))
    _C_NOSPLIT_GRAINS.get_or_create_ptr()[][].store(Int64(0))
    _C_EMIT_ROWS.get_or_create_ptr()[][].store(Int64(0))
    _C_EMIT_MORSELS.get_or_create_ptr()[][].store(Int64(0))


@always_inline
def cursor_grain_split_enabled() raises -> Bool:
    """The split gate, default ON. A relaxed atomic load."""
    return _G_SPLIT_GATE.get_or_create_ptr()[][].load() != _GATE_OFF


def set_cursor_grain_split_enabled(on: Bool) raises:
    """Turn the split on or off for the process. A program maps its own flag
    to this setter."""
    _G_SPLIT_GATE.get_or_create_ptr()[][].store(Int64(1) if on else _GATE_OFF)
