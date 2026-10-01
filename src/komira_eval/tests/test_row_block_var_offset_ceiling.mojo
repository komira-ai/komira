# =============================================================================
# The ROW-FORMAT var-storage offset field, pinned
# =============================================================================
#
# A `RowBlock` var-width cell is an 8-BYTE DESCRIPTOR, `(length << 32) |
# (offset & 0xFFFFFFFF)`, with the payload at
# `_var_storage[offset : offset + length]`. Both halves are 32 bits; the cursor
# (`var_storage_used`) and the capacity are 64-bit `Int`. Nothing bounded the
# one against the other until `VAR_DESC_OFFSET_MAX`.
#
# ⛔ THE FAILURE IS SILENT, WHICH IS WHY IT IS A REFUSAL AND NOT A DOC NOTE.
# The payload is written at the TRUE cursor, so a truncated offset is always
# SMALLER than the true one and therefore always inside the live allocation:
# every bounds check passes, the row count is right, and the cell simply names
# ANOTHER ROW'S BYTES. `var_string_key_payload_at`'s own SAFETY block states
# the invariant this guard is what actually enforces —
# `offset + length <= var_storage_used <= capacity` — which a wrapped offset
# satisfies while pointing at the wrong run.
#
# ⚠ REACHABILITY IS NOT "one batch". `RowHashAggTable.rows` is an ACCUMULATOR
# (`komira_engine_dispatch.agg_spill_driver` builds one per spill run;
# `from_spilled_group_rows` reloads a whole image into one), so this heap is
# bounded by a spilled aggregate's GROUP COUNT, not by a morsel.
#
# ⛔ NOT the Arrow Int32 output ceiling (2_147_483_647, SIGNED) — different
# field, different sign, and that one is already guarded and already promotes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_eval.row_format import RowBlock
from komira_eval.row_format.row_block import VAR_DESC_OFFSET_MAX


def test_row_block_var_reserve_past_the_offset_field_is_refused() raises:
    """A reservation whose resulting cursor would not fit the 32-bit offset
    field must RAISE — ahead of the multi-GiB allocation it would otherwise
    make, which is why the check sits before the regrow rather than at the
    descriptor write."""
    var rb = RowBlock(16)
    with assert_raises():
        rb.reserve_var_bytes(1 << 32)


def test_row_block_var_reserve_below_the_offset_field_is_admitted() raises:
    """The guard's other direction: an ordinary reservation still grows, and
    the cursor is untouched by a reservation."""
    var rb = RowBlock(16)
    rb.reserve_var_bytes(4096)
    assert_equal(rb.var_storage_used, 0)
    rb.reserve_var_bytes(64)
    assert_equal(rb.var_storage_used, 0)


def test_row_block_offset_ceiling_is_the_descriptor_field_width() raises:
    """2**32-1, not Arrow's SIGNED 2**31-1. The two numbers are routinely
    confused and they bound DIFFERENT fields: setting this to the Arrow value
    would refuse 2 GiB the descriptor can address, setting it to 2**32 would
    admit one cursor it cannot."""
    assert_equal(VAR_DESC_OFFSET_MAX, 4294967295)
    assert_equal(VAR_DESC_OFFSET_MAX, (1 << 32) - 1)


def test_row_block_var_boundary_is_exact_and_a_refusal_mutates_nothing() raises:
    """⭐ THE EXACT EDGE — both sides of `need == 2**32 - 1` — and the state a
    REFUSED write leaves behind.

    The two reservation tests above sit at `1 << 32` from an empty block and
    at 4 KiB, so a guard that refused ONE BYTE EARLY
    (`used + additional >= VAR_DESC_OFFSET_MAX`) passed both.

    ⚠ WHY THE CAPACITY IS FORGED HERE AND NOT IN THE COLUMN-STORAGE TWIN.
    `OwnedAlignedBuffer.reserve` ZERO-FILLS every byte it adds ("deterministic
    SIMD over-read"), so a real 2**32-1-byte var region is a 4 GiB memset —
    seconds of wall time. Instead the grow decision's two inputs are
    set to the edge: capacity == 2**32-1 (so the admitted reservation does
    not grow) and the cursor 8 bytes under it. Neither call below writes a
    byte into `_var_storage`: the admitted one returns at the capacity test,
    and the refused write raises in `reserve_var_bytes` BEFORE its memcpy —
    which is exactly the property the last half of this test pins. The
    truthful fields are restored before the block drops.
    """
    var rb = RowBlock(16)
    rb.reserve_rows(2)
    rb.reserve_var_bytes(64)
    var real_cap = rb.var_storage_capacity

    rb.var_storage_capacity = VAR_DESC_OFFSET_MAX
    rb.var_storage_used = VAR_DESC_OFFSET_MAX - 8
    rb.reserve_var_bytes(8)  # need == 2**32 - 1: ADMITTED
    with assert_raises():
        rb.reserve_var_bytes(9)  # need == 2**32: REFUSED
    assert_equal(
        rb.var_storage_used,
        VAR_DESC_OFFSET_MAX - 8,
        "a reservation never moves the cursor, admitted or refused",
    )

    # A cursor AT the ceiling (the state after a real payload ended exactly
    # on its last byte), then a one-byte write through the production writer.
    rb.var_storage_used = VAR_DESC_OFFSET_MAX
    var cell_before = rb._fixed_storage.read_u64_le_at(16)
    var one = String("z")
    with assert_raises():
        rb.write_var_string_cell(1, 0, one.as_bytes())
    assert_equal(
        rb.var_storage_used,
        VAR_DESC_OFFSET_MAX,
        "a REFUSED append must not advance the cursor",
    )
    assert_equal(
        rb._fixed_storage.read_u64_le_at(16),
        cell_before,
        "a REFUSED append must not write the target row's descriptor",
    )

    rb.var_storage_capacity = real_cap
    rb.var_storage_used = 0


def main() raises:
    var s = TestSuite()
    s.test[test_row_block_var_reserve_past_the_offset_field_is_refused]()
    s.test[test_row_block_var_reserve_below_the_offset_field_is_admitted]()
    s.test[test_row_block_offset_ceiling_is_the_descriptor_field_width]()
    s.test[test_row_block_var_boundary_is_exact_and_a_refusal_mutates_nothing]()
    s^.run()
