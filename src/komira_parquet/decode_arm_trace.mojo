# =============================================================================
# decode_arm_trace — the decode-path arms and their fire COUNTERS
# =============================================================================
#
# Four decode sites each have two arms, chosen at run time:
#
#   DELTA PAGE   `DeltaDecoder.__init__` stages each encoded DELTA page into
#                its owned buffer with one bulk `memcpy` (gate on), or one
#                byte at a time through `List.append` (gate off).
#   DICT RESOLVE the dictionary decoder resolves a column chunk's codes with
#                the fused gather (gate on) or the original loop (gate off).
#   DICT STRING  a densified dictionary STRING chunk is handed to its Column
#   SHARE        by Arc share (gate on) or by a second full copy (gate off).
#   DICT CODES   a dictionary-preserving STRING chunk's code buffer is shared
#   MOVE         into its Column (gate on) or copied twice (gate off).
#
# ⚠ THE ARMS ARE RUN-TIME, ON PURPOSE, AND ALL DEFAULT **ON**. Comparing two
# separately-compiled binaries measures layout as much as the change, so the
# gate-off shapes are RETAINED and both arms run from one binary: a program
# turns an arm off by calling its setter (`set_*_enabled(False)`), typically
# from its own command-line flag. This module reads no environment.
#
# ⚠ THE OBSERVABLE IS A COUNT, NOT A FLAG. A lever that never ARMS measures a
# perfect null, indistinguishable from a lever that armed and did nothing. Each
# arm therefore counts BOTH of its legs, so `fast == 0 and slow > 0` diagnoses
# "the gate was read and the arm declined" and `fast == 0 and slow == 0`
# diagnoses "this route never reached the site at all".
#
# GRANULARITY. `delta-page-*` is one relaxed atomic add per DELTA **page**
# (thousands per scan, never per byte); `dict-resolve-*` is one per **column
# chunk**. Neither is in a per-value loop.
#
# Mechanism: name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot. No address rebuilt
# from an integer, no UnsafePointer in any public signature.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


# -----------------------------------------------------------------------------
# The process-global slots.
# -----------------------------------------------------------------------------


def _init_decode_arm_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate one counter/latch Atomic per
    process, initialised to 0."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init, concrete origin from `to=`. `Atomic` is not
    # movable-by-value, so its interior scalar must be initialised in place
    # before the `OwnedPointer` takes ownership; the raw pointer never leaves
    # this function (the return type is `OwnedPointer`).
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_DELTA_MEMCPY = _Global[
    "komira_parquet_decode_arm_delta_memcpy", _init_decode_arm_slot
]
comptime _C_DELTA_BYTECOPY = _Global[
    "komira_parquet_decode_arm_delta_bytecopy", _init_decode_arm_slot
]
comptime _C_DICT_FUSED = _Global[
    "komira_parquet_decode_arm_dict_fused", _init_decode_arm_slot
]
comptime _C_DICT_LEGACY = _Global[
    "komira_parquet_decode_arm_dict_legacy", _init_decode_arm_slot
]
# The sub-row-group cursor route's own dictionary gather, a DIFFERENT symbol
# from `dictionary::resolve_*`. Counted separately so a null on one route cannot
# be read as a null on the other.
comptime _C_FLAT_FUSED = _Global[
    "komira_parquet_decode_arm_flat_fused", _init_decode_arm_slot
]
comptime _C_FLAT_LEGACY = _Global[
    "komira_parquet_decode_arm_flat_legacy", _init_decode_arm_slot
]
# The dictionary-string share arm: the densified RLE_DICTIONARY STRING chunk
# handed to its Column by Arc share vs by `Column.from_string` memcpy.
comptime _C_DSTR_SHARE = _Global[
    "komira_parquet_decode_arm_dict_string_share", _init_decode_arm_slot
]
comptime _C_DSTR_COPY = _Global[
    "komira_parquet_decode_arm_dict_string_copy", _init_decode_arm_slot
]

# Gate latches: 0 = UNSET (the default, ON), 1 = ON, 2 = OFF. A setter
# stores 1 or 2; `reset_decode_arm_gates` stores 0 again.
comptime _G_DELTA_MEMCPY = _Global[
    "komira_parquet_gate_delta_page_memcpy", _init_decode_arm_slot
]
comptime _G_DICT_FUSED = _Global[
    "komira_parquet_gate_dict_resolve_fused", _init_decode_arm_slot
]
comptime _G_DSTR_SHARE = _Global[
    "komira_parquet_gate_dict_string_share", _init_decode_arm_slot
]
comptime _G_DCODES_MOVE = _Global[
    "komira_parquet_gate_dict_codes_move", _init_decode_arm_slot
]

comptime _GATE_UNSET: Int64 = 0
comptime _GATE_ON: Int64 = 1
comptime _GATE_OFF: Int64 = 2


# -----------------------------------------------------------------------------
# Counters — one relaxed atomic add per DELTA PAGE / per COLUMN CHUNK.
# -----------------------------------------------------------------------------


@always_inline
def incr_delta_page_memcpy() raises:
    """Record one DELTA page staged by the BULK arm (`memcpy`).
    `raises` only to propagate `_Global.get_or_create_ptr`'s signature."""
    # SAFETY: `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); the `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type and is confined to this helper.
    _ = _C_DELTA_MEMCPY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_delta_page_bytecopy() raises:
    """Record one DELTA page staged by the byte-at-a-time arm (gate off)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_DELTA_BYTECOPY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_dict_resolve_fused() raises:
    """Record one dictionary column chunk resolved by the FUSED arm."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_DICT_FUSED.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_dict_resolve_legacy() raises:
    """Record one dictionary column chunk resolved by the LEGACY arm."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_DICT_LEGACY.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_flat_gather_fused() raises:
    """Record one sub-row-group dictionary column resolved by the FUSED arm."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_FLAT_FUSED.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_flat_gather_legacy() raises:
    """Record one sub-row-group dictionary column resolved by the LEGACY arm."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_FLAT_LEGACY.get_or_create_ptr()[][].fetch_add(Int64(1))


def flat_gather_fused_count() raises -> Int:
    """Process-wide `flat-gather-fused` fire count."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_FLAT_FUSED.get_or_create_ptr()[][].load())


def flat_gather_legacy_count() raises -> Int:
    """Process-wide `flat-gather-LEGACY` fire count."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_FLAT_LEGACY.get_or_create_ptr()[][].load())


def delta_page_memcpy_count() raises -> Int:
    """Process-wide `delta-page-memcpy` fire count."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_DELTA_MEMCPY.get_or_create_ptr()[][].load())


def delta_page_bytecopy_count() raises -> Int:
    """Process-wide `delta-page-BYTECOPY` fire count."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_DELTA_BYTECOPY.get_or_create_ptr()[][].load())


def dict_resolve_fused_count() raises -> Int:
    """Process-wide `dict-resolve-fused` fire count."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_DICT_FUSED.get_or_create_ptr()[][].load())


def dict_resolve_legacy_count() raises -> Int:
    """Process-wide `dict-resolve-LEGACY` fire count."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_DICT_LEGACY.get_or_create_ptr()[][].load())


@always_inline
def incr_dict_string_share() raises:
    """Record one densified RLE_DICTIONARY STRING chunk whose fresh
    `StringArray` was Arc-SHARED into its Column (the string-share gate ON)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_DSTR_SHARE.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_dict_string_copy() raises:
    """Record one densified RLE_DICTIONARY STRING chunk that took the
    `Column.from_string` COPY arm (gate OFF)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _ = _C_DSTR_COPY.get_or_create_ptr()[][].fetch_add(Int64(1))


def dict_string_share_count() raises -> Int:
    """Process-wide fire count of the string-share arm (chunks Arc-shared)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_DSTR_SHARE.get_or_create_ptr()[][].load())


def dict_string_copy_count() raises -> Int:
    """Process-wide `dict-string-COPY` fire count (chunks deep-copied)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return Int(_C_DSTR_COPY.get_or_create_ptr()[][].load())


def reset_decode_arm_counts() raises:
    """Zero every arm counter.

    ⚠ TEST SETUP ONLY. Production must never reset these: the counters being
    process-CUMULATIVE is what lets a join route account for its build phase and
    its probe phase from ONE dump site."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _C_DELTA_MEMCPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_DELTA_BYTECOPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_DICT_FUSED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_DICT_LEGACY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_FLAT_FUSED.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_FLAT_LEGACY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_DSTR_SHARE.get_or_create_ptr()[][].store(Scalar[DType.int64](0))
    _C_DSTR_COPY.get_or_create_ptr()[][].store(Scalar[DType.int64](0))


# -----------------------------------------------------------------------------
# Gates — set by a setter, read BY VALUE. All DEFAULT ON.
# -----------------------------------------------------------------------------


@always_inline
def delta_page_memcpy_enabled() raises -> Bool:
    """The DELTA PAGE gate, DEFAULT ON (see `set_delta_page_memcpy_enabled`).

    A relaxed atomic load, so this is safe to call per DELTA page (it is — see
    `DeltaDecoder.__init__`)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return _G_DELTA_MEMCPY.get_or_create_ptr()[][].load() != _GATE_OFF


@always_inline
def dict_resolve_fused_enabled() raises -> Bool:
    """The DICT RESOLVE gate, DEFAULT ON (see `set_dict_resolve_fused_enabled`)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return _G_DICT_FUSED.get_or_create_ptr()[][].load() != _GATE_OFF


@always_inline
def dict_string_share_enabled() raises -> Bool:
    """The dictionary-string share gate, DEFAULT ON (see
    `set_dict_string_share_enabled`).

    THE SITE. A dictionary decoder that densifies an RLE_DICTIONARY STRING
    chunk allocates BOTH output buffers fresh and then hands the result to
    `Column.from_string` — a SECOND full memcpy of the offsets and the payload,
    for no semantic reason. ON, the fresh array is Arc-shared into its Column.

    OFF restores the copy: the rollback path AND the byte-equivalence oracle
    the share is tested against."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return _G_DSTR_SHARE.get_or_create_ptr()[][].load() != _GATE_OFF


def string_dict_column_move_enabled() raises -> Bool:
    """The dictionary-codes move gate, DEFAULT ON (see
    `set_string_dict_column_move_enabled`).

    THE SITE. A dictionary-preserving decode of a NON-NULL RLE_DICTIONARY
    STRING chunk copies the code buffer into a `StringDictionaryArray`, and
    `Column.from_dictionary` copies it AGAIN into the Column — two full copies
    of a buffer the decoder had just built and never touches again. ON, the
    codes are Arc-shared into the Column instead (same Column, same buffer
    lengths). OFF keeps both copies: rollback and byte-equivalence oracle."""
    # SAFETY: see `incr_delta_page_memcpy`.
    return _G_DCODES_MOVE.get_or_create_ptr()[][].load() != _GATE_OFF


def set_dict_string_share_enabled(on: Bool) raises:
    """Turn the dictionary-string share arm on (Arc share) or off (copy).

    A byte-equivalence test decodes the SAME bytes twice in ONE process with
    the arm flipped in between."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _G_DSTR_SHARE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def reset_decode_arm_gates() raises:
    """Drop every gate back to its default (ON), as if no setter had run.

    For a test that flips the gates, and for a program that hands the choice
    back to the defaults."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _G_DELTA_MEMCPY.get_or_create_ptr()[][].store(_GATE_UNSET)
    _G_DICT_FUSED.get_or_create_ptr()[][].store(_GATE_UNSET)
    _G_DSTR_SHARE.get_or_create_ptr()[][].store(_GATE_UNSET)
    _G_DCODES_MOVE.get_or_create_ptr()[][].store(_GATE_UNSET)


def set_delta_page_memcpy_enabled(on: Bool) raises:
    """Turn the DELTA PAGE arm on (bulk `memcpy`) or off (byte loop) for the
    process. A program maps its own flag to this setter."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _G_DELTA_MEMCPY.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_dict_resolve_fused_enabled(on: Bool) raises:
    """Turn the DICT RESOLVE arm on (fused gather) or off (original loop)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _G_DICT_FUSED.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


def set_string_dict_column_move_enabled(on: Bool) raises:
    """Turn the dictionary-codes move arm on (share the codes) or off (copy
    them)."""
    # SAFETY: see `incr_delta_page_memcpy`.
    _G_DCODES_MOVE.get_or_create_ptr()[][].store(_GATE_ON if on else _GATE_OFF)


# -----------------------------------------------------------------------------
# The NON-RAISING composite used by `DeltaDecoder.__init__`.
# -----------------------------------------------------------------------------


@always_inline
def take_delta_page_arm() -> Bool:
    """Select the DELTA PAGE staging arm AND record the fire, in ONE
    non-raising call. Returns True for the `memcpy` arm, False for the byte
    loop.

    ⚠ WHY THIS EXISTS AT ALL. `DeltaDecoder.__init__` is a NON-raising `def`,
    and every accessor above is `raises` — not because it can fail, but
    because the stdlib `_Global.get_or_create_ptr` signature is declared that
    way and the obligation propagates. Making the constructor `raises` instead
    would push the obligation onto every DELTA call site, to buy nothing.

    ⛔ THE `except` ARM RETURNS THE DEFAULT ARM, NOT THE BYTE LOOP. A
    process-global slot allocation cannot fail here; if it somehow did,
    defaulting to `False` would silently run every decode on the byte loop.
    The counters are the only thing lost.
    """
    try:
        if delta_page_memcpy_enabled():
            incr_delta_page_memcpy()
            return True
        incr_delta_page_bytecopy()
        return False
    except:
        return True  # cov: unreachable the _Global slot accessors never raise in practice
