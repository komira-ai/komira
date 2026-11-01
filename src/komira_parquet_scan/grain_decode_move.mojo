# =============================================================================
# grain_decode_move — the per-grain copy of the cursor-grain scan, and its
# move arm
# =============================================================================
#
# `cursor_grain_feed.cursor_grain_next` builds one grain-sized batch per call
# from live column cursors. A FLAT column costs two passes over the grain's
# bytes: the cursor copies the page window into the worker's fixed value
# buffer, then the column builder copies that buffer element by element into
# a fresh array of the SAME physical type (INT32, INT64, FLOAT, DOUBLE: the
# scan keeps the physical width). The second pass changes no byte.
#
# With the gate on, the cursor decodes into a buffer the column then takes
# over (no second pass). The grain schedule, and so the batch sequence and
# any fold order, is unchanged: the two arms give byte-identical columns on
# every admitted type, floats included.
#
# Why the grain still owns its bytes: the morsel is moved into the sink, which
# may keep it after the worker fills its next grain, so a column borrowing the
# worker's buffer would dangle.
#
# Gate: `grain_decode_move_enabled`, default OFF, set with
# `set_grain_decode_move_enabled`. Counters (always on): the bytes and columns
# built by copy, by move, and by a dictionary resolve (a gather, unchanged by
# the gate; it tells "no flat column" apart from "the move fired").
# `grain_move_trace_dump` prints them when `set_grain_move_trace_enabled(True)`.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, alloc


def _init_grain_move_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init function: one zeroed counter per process."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: `raw` is the one fresh allocation above; the scalar is written
    # in place before `OwnedPointer` takes ownership, and `raw` never leaves
    # this function.
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_FLAT_COPY_BYTES = _Global["komira_parquet_grain_flat_copy_bytes", _init_grain_move_slot]
comptime _C_FLAT_MOVE_BYTES = _Global["komira_parquet_grain_flat_move_bytes", _init_grain_move_slot]
comptime _C_DICT_RESOLVE_BYTES = _Global["komira_parquet_grain_dict_resolve_bytes", _init_grain_move_slot]
comptime _C_FLAT_COPY_COLS = _Global["komira_parquet_grain_flat_copy_cols", _init_grain_move_slot]
comptime _C_FLAT_MOVE_COLS = _Global["komira_parquet_grain_flat_move_cols", _init_grain_move_slot]
comptime _C_DICT_RESOLVE_COLS = _Global["komira_parquet_grain_dict_resolve_cols", _init_grain_move_slot]
comptime _G_MOVE_GATE = _Global["komira_parquet_gate_grain_decode_move", _init_grain_move_slot]
comptime _G_MOVE_TRACE = _Global["komira_parquet_gate_grain_move_trace", _init_grain_move_slot]

comptime _GATE_ON: Int64 = 1
comptime _GATE_OFF: Int64 = 2


@always_inline
def incr_grain_flat_copy(nbytes: Int) raises:
    """One flat grain column built by the element-wise copy."""
    _ = _C_FLAT_COPY_BYTES.get_or_create_ptr()[][].fetch_add(Int64(nbytes))
    _ = _C_FLAT_COPY_COLS.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_grain_flat_move(nbytes: Int) raises:
    """One flat grain column whose decode buffer was moved into the column."""
    _ = _C_FLAT_MOVE_BYTES.get_or_create_ptr()[][].fetch_add(Int64(nbytes))
    _ = _C_FLAT_MOVE_COLS.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_grain_dict_resolve(nbytes: Int) raises:
    """One dictionary grain column resolved code to value."""
    _ = _C_DICT_RESOLVE_BYTES.get_or_create_ptr()[][].fetch_add(Int64(nbytes))
    _ = _C_DICT_RESOLVE_COLS.get_or_create_ptr()[][].fetch_add(Int64(1))


def grain_flat_copy_bytes() raises -> Int:
    """Bytes built by the copy arm (0 when the gate is on)."""
    return Int(_C_FLAT_COPY_BYTES.get_or_create_ptr()[][].load())


def grain_flat_move_bytes() raises -> Int:
    """Bytes handed to a column by move (0 when the gate is off)."""
    return Int(_C_FLAT_MOVE_BYTES.get_or_create_ptr()[][].load())


def grain_dict_resolve_bytes() raises -> Int:
    """Bytes written by the dictionary resolve."""
    return Int(_C_DICT_RESOLVE_BYTES.get_or_create_ptr()[][].load())


def grain_flat_copy_cols() raises -> Int:
    """Columns built by the copy arm."""
    return Int(_C_FLAT_COPY_COLS.get_or_create_ptr()[][].load())


def grain_flat_move_cols() raises -> Int:
    """Columns built by the move arm."""
    return Int(_C_FLAT_MOVE_COLS.get_or_create_ptr()[][].load())


def grain_dict_resolve_cols() raises -> Int:
    """Columns built by the dictionary resolve."""
    return Int(_C_DICT_RESOLVE_COLS.get_or_create_ptr()[][].load())


def reset_grain_move_counts() raises:
    """Zero the six counters (a test's setup)."""
    _C_FLAT_COPY_BYTES.get_or_create_ptr()[][].store(Int64(0))
    _C_FLAT_MOVE_BYTES.get_or_create_ptr()[][].store(Int64(0))
    _C_DICT_RESOLVE_BYTES.get_or_create_ptr()[][].store(Int64(0))
    _C_FLAT_COPY_COLS.get_or_create_ptr()[][].store(Int64(0))
    _C_FLAT_MOVE_COLS.get_or_create_ptr()[][].store(Int64(0))
    _C_DICT_RESOLVE_COLS.get_or_create_ptr()[][].store(Int64(0))


@always_inline
def grain_decode_move_enabled() raises -> Bool:
    """The move gate, default OFF. A relaxed atomic load."""
    return _G_MOVE_GATE.get_or_create_ptr()[][].load() == _GATE_ON


def set_grain_decode_move_enabled(on: Bool) raises:
    """Turn the move arm on or off for the process."""
    _G_MOVE_GATE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


@always_inline
def grain_move_trace_enabled() raises -> Bool:
    """The trace print gate, default OFF."""
    return _G_MOVE_TRACE.get_or_create_ptr()[][].load() == _GATE_ON


def set_grain_move_trace_enabled(on: Bool) raises:
    """Turn the trace print on or off for the process."""
    _G_MOVE_TRACE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def grain_move_trace_dump(site: StaticString) raises:
    """Print the per-arm byte counts when the trace is on. Called first by
    `cursor_grain_feed.cursor_grain_trace_dump`, so it prints wherever the
    cursor-grain line prints. Gate off: copy bytes large, move bytes 0; gate
    on: the reverse. Both 0 with dictionary bytes: no flat column. All 0: the
    cursor-grain route never ran."""
    if not grain_move_trace_enabled():
        return
    print(
        "[grain-move] at=", site,
        " flat-copy-bytes=", grain_flat_copy_bytes(),
        " (cols=", grain_flat_copy_cols(), ")",
        " flat-move-bytes=", grain_flat_move_bytes(),
        " (cols=", grain_flat_move_cols(), ")",
        " dict-resolve-bytes=", grain_dict_resolve_bytes(),
        " (cols=", grain_dict_resolve_cols(), ")",
        " | gate=", grain_decode_move_enabled(),
        sep="",
    )
