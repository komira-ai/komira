# =============================================================================
# payload_sel_trace — the payload selected-decode gate + its arming counters
# =============================================================================
#
# WHY THIS FILE EXISTS. When a pushed-down filter keeps a small share of a row
# group, decoding the payload (non-filter) columns in full and then gathering
# the survivors materialises every value the filter is about to throw away.
# A selected decode walks the column chunk page by page and materialises ONLY
# the selected rows. This gate chooses between the two in the scan, and the
# counters say which arm ran.
#
# ⚠ THE OBSERVABLE IS A COUNT, NOT A FLAG. A lever that never ARMS measures a
# perfect null, indistinguishable from one that armed and did nothing. So BOTH
# legs are counted, per (row group x payload decode):
#   * `hit`      — the selected decode ran and every payload column was
#                  accepted by the gather kernel.
#   * `DECLINE`  — the selected decode ran and at least one column's shape was
#                  refused (mixed encodings in one chunk, DELTA / BSS pages,
#                  V2-with-levels, FLBA, DECIMAL, dict+preserve_dict); the
#                  caller fell back to full decode + gather.
#   * `SKIP`     — the gate itself declined before any decode: not selective
#                  enough, zero survivors, or a preloaded payload batch.
# `hit == 0 and DECLINE == 0 and SKIP == 0` diagnoses "this route never reached
# the site at all" — which is a WRONG ARM MAP, not a null result.
#
#   * `policy_skip` — a selective row group the default VAR_WIDTH mode left
#                  on the full decode because its payload is all fixed-width.
#
# The gate is a three-mode switch, OFF by default, set with
# `set_payload_sel_decode_mode`; nothing here reads the environment.
#
# Mechanism: name-keyed, init-once, cross-compile-unit process-global
# `Atomic[int64]` via the stdlib `_Global` runtime slot — the
# `scan_copy_trace.mojo` / `decode_arm_trace.mojo` idiom. No address rebuilt
# from an integer, no UnsafePointer in any public signature.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc


def _init_payload_sel_slot() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate one counter/latch Atomic per
    process, initialised to 0."""
    var raw = alloc[AtomicI64](1)
    # SAFETY: module-private init, concrete origin from `to=`. `Atomic` is not
    # movable-by-value, so its interior scalar must be initialised in place
    # before the `OwnedPointer` takes ownership; the raw pointer never leaves
    # this function (the return type is `OwnedPointer`).
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _C_PSEL_HIT = _Global[
    "komira_parquet_payload_sel_hit", _init_payload_sel_slot
]
comptime _C_PSEL_DECLINE = _Global[
    "komira_parquet_payload_sel_decline", _init_payload_sel_slot
]
comptime _C_PSEL_SKIP = _Global[
    "komira_parquet_payload_sel_skip", _init_payload_sel_slot
]
comptime _C_PSEL_ROWS_DECODED = _Global[
    "komira_parquet_payload_sel_rows_decoded", _init_payload_sel_slot
]
comptime _C_PSEL_ROWS_TOTAL = _Global[
    "komira_parquet_payload_sel_rows_total", _init_payload_sel_slot
]
comptime _C_PSEL_POLICY_SKIP = _Global[
    "komira_parquet_payload_sel_policy_skip", _init_payload_sel_slot
]
comptime _G_PSEL = _Global[
    "komira_parquet_gate_payload_sel", _init_payload_sel_slot
]

# The latched slot stores `mode + 1`; 0 means "no setter has run" (OFF).
comptime _GATE_UNRESOLVED: Int64 = 0

# ⭐ THE THREE MODES.
#
# A FIXED-WIDTH payload gains nothing from the selected decode: the full
# decode is one memcpy per page and the selection kernel does one per
# surviving run, so the per-run calls cost more than they save.
# A VARIABLE-WIDTH payload is the opposite shape: the full decode copies every
# string body (PLAIN) or densifies every dictionary code into a string (dict),
# then the gather reads the survivors back.
#
#   * `PAYLOAD_SEL_OFF` (THE DEFAULT): never arm.
#   * `PAYLOAD_SEL_VAR_WIDTH`: arm only when every payload column is one the
#     selection kernel accepts and at least one is variable-width
#     (BYTE_ARRAY). A payload that is entirely fixed-width keeps the full
#     decode.
#   * `PAYLOAD_SEL_ALL`: arm on every accepted payload shape (the
#     measurement arm for fixed-width payloads, kept reproducible).
#
# ⛔ WHY VAR_WIDTH IS NOT THE DEFAULT. The selection kernel zero-fills a NULL
# slot where the full decode leaves other bytes. Arrow leaves a NULL slot's
# value unspecified, so that is not a wrong answer — but a test that compares
# RAW value buffers, NULL slots included, would see the difference, and
# promoting the mode means restating those contracts. The staged filter's
# PAYLOAD decode follows this mode too, so under the default it is a full
# decode + gather.
comptime PAYLOAD_SEL_OFF: Int = 0
comptime PAYLOAD_SEL_VAR_WIDTH: Int = 1
comptime PAYLOAD_SEL_ALL: Int = 2


@always_inline
def incr_payload_sel_hit(rows_decoded: Int, rows_total: Int) raises:
    """One row group whose payload columns were decoded SELECTED. Also records
    the row ledger — `rows_decoded` values materialised against `rows_total`
    the full decode would have materialised — because the wall claim is a
    BYTES claim and a fire count alone cannot carry it.

    `raises` only to propagate `_Global.get_or_create_ptr`'s signature."""
    # SAFETY: `_Global.get_or_create_ptr` returns the
    # process-global slot; the pointer never escapes this function.
    _ = _C_PSEL_HIT.get_or_create_ptr()[][].fetch_add(Int64(1))
    _ = _C_PSEL_ROWS_DECODED.get_or_create_ptr()[][].fetch_add(
        Int64(rows_decoded)
    )
    _ = _C_PSEL_ROWS_TOTAL.get_or_create_ptr()[][].fetch_add(
        Int64(rows_total)
    )


@always_inline
def incr_payload_sel_decline() raises:
    """One row group where the selected decode RAN and a column's shape was
    refused by the gather kernel — the caller fell back to full decode."""
    # SAFETY: see `incr_payload_sel_hit`.
    _ = _C_PSEL_DECLINE.get_or_create_ptr()[][].fetch_add(
        Int64(1)
    )


@always_inline
def incr_payload_sel_skip() raises:
    """One row group where the GATE declined before any selected decode ran."""
    # SAFETY: see `incr_payload_sel_hit`.
    _ = _C_PSEL_SKIP.get_or_create_ptr()[][].fetch_add(Int64(1))


@always_inline
def incr_payload_sel_policy_skip() raises:
    """One SELECTIVE row group the VAR_WIDTH mode left on the full decode
    because every payload column is fixed-width. Counted apart from `SKIP`
    (not selective enough) so a fixed-width cell reads as a POLICY decision,
    not as a route that never reached the site."""
    # SAFETY: see `incr_payload_sel_hit`.
    _ = _C_PSEL_POLICY_SKIP.get_or_create_ptr()[][].fetch_add(Int64(1))


def payload_sel_policy_skip_count() raises -> Int:
    """Selective row groups left on the full decode by the VAR_WIDTH policy."""
    # SAFETY: see `incr_payload_sel_hit`.
    return Int(_C_PSEL_POLICY_SKIP.get_or_create_ptr()[][].load())


def payload_sel_hit_count() raises -> Int:
    """Row groups whose payload decoded SELECTED. Process-cumulative."""
    # SAFETY: see `incr_payload_sel_hit`.
    return Int(_C_PSEL_HIT.get_or_create_ptr()[][].load())


def payload_sel_decline_count() raises -> Int:
    """Row groups where the kernel refused a column shape. Cumulative."""
    # SAFETY: see `incr_payload_sel_hit`.
    return Int(_C_PSEL_DECLINE.get_or_create_ptr()[][].load())


def payload_sel_skip_count() raises -> Int:
    """Row groups where the gate declined before decoding. Cumulative."""
    # SAFETY: see `incr_payload_sel_hit`.
    return Int(_C_PSEL_SKIP.get_or_create_ptr()[][].load())


def payload_sel_rows_decoded() raises -> Int:
    """Payload values materialised on the SELECTED arm. Cumulative."""
    # SAFETY: see `incr_payload_sel_hit`.
    return Int(_C_PSEL_ROWS_DECODED.get_or_create_ptr()[][].load())


def payload_sel_rows_total() raises -> Int:
    """Payload values the FULL decode would have materialised for those same
    row groups. `rows_total - rows_decoded` is the lever's byte claim."""
    # SAFETY: see `incr_payload_sel_hit`.
    return Int(_C_PSEL_ROWS_TOTAL.get_or_create_ptr()[][].load())


def reset_payload_sel_counts() raises:
    """Zero every counter. For tests that assert a per-scan delta."""
    # SAFETY: see `incr_payload_sel_hit`.
    _C_PSEL_HIT.get_or_create_ptr()[][].store(Int64(0))
    _C_PSEL_DECLINE.get_or_create_ptr()[][].store(Int64(0))
    _C_PSEL_SKIP.get_or_create_ptr()[][].store(Int64(0))
    _C_PSEL_ROWS_DECODED.get_or_create_ptr()[][].store(Int64(0))
    _C_PSEL_ROWS_TOTAL.get_or_create_ptr()[][].store(Int64(0))
    _C_PSEL_POLICY_SKIP.get_or_create_ptr()[][].store(Int64(0))


@always_inline
def payload_sel_decode_mode() raises -> Int:
    """The payload selected-decode gate: one of `PAYLOAD_SEL_OFF` (the default) /
    `PAYLOAD_SEL_VAR_WIDTH` / `PAYLOAD_SEL_ALL`. See the mode table above.

    A relaxed atomic load, so this is safe to call per row group.
    """
    # SAFETY: see `incr_payload_sel_hit`.
    var p = _G_PSEL.get_or_create_ptr()
    var cur = p[][].load()
    if cur != _GATE_UNRESOLVED:
        return Int(cur) - 1
    return PAYLOAD_SEL_OFF


@always_inline
def payload_sel_decode_enabled() raises -> Bool:
    """True unless the gate is OFF (the trace line's `gate:` field)."""
    return payload_sel_decode_mode() != PAYLOAD_SEL_OFF


def set_payload_sel_decode_mode(mode: Int) raises:
    """Set the gate for the process to one of the three modes. A program maps
    its own flag to this setter.

    Raises:
        Error if `mode` is not one of the three modes.
    """
    if mode != PAYLOAD_SEL_OFF and mode != PAYLOAD_SEL_VAR_WIDTH and mode != PAYLOAD_SEL_ALL:
        raise Error("parquet: unknown payload selection mode " + String(mode))
    # SAFETY: see `incr_payload_sel_hit`.
    _G_PSEL.get_or_create_ptr()[][].store(Int64(mode + 1))


def reset_payload_sel_gate() raises:
    """Drop the gate back to its default (OFF), as if no setter had run."""
    # SAFETY: see `incr_payload_sel_hit`.
    _G_PSEL.get_or_create_ptr()[][].store(_GATE_UNRESOLVED)
