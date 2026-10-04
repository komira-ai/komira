# =============================================================================
# VARHEAP-OFFSET-CEILING — the 32-bit var-heap offset field, pinned
# =============================================================================
#
# ⭐ WHAT THIS FILE IS ABOUT, AND WHY IT IS NOT AN ARROW-OFFSET TEST.
#
# `ColumnFormatStorage` stores a var-width (STRING / BINARY) slot as an 8-BYTE
# DESCRIPTOR CELL packed `(length << 32) | (offset & 0xFFFFFFFF)`, with the
# payload bytes living at `var_data_heaps[var_idx][offset : offset + length]`.
# The OFFSET half is therefore an UNSIGNED 32-BIT field and the arena it
# indexes is addressed by a 64-bit `Int` cursor (`var_data_used`) with a 64-bit
# capacity. Nothing in the storage bounded the cursor against the field.
#
# ⛔ THIS IS NOT THE `ARROW_INT32_OFFSET_MAX` (2_147_483_647, SIGNED) CEILING,
# and confusing the two is the easy mistake here. That one is on the OUTPUT
# side, it is guarded by `check_int32_offsets` / `should_promote_offsets` from
# dozens of call sites, and its failure is a NAMED, LOUD `ArrowOffsetOverflow`.
# This one is INTERNAL to the group-key / join-key store, its wrap point is
# 2**32 = 4_294_967_296 (UNSIGNED — the pack masks with `0xFFFFFFFF` and the
# unpack reads it back non-negative), and before the guard these tests pin it
# had NO check of any kind at any of its three writers.
#
# ⛔ WHY A WRAP HERE IS THE WORST OUTCOME IN THIS ENGINE. The payload bytes are
# written at the TRUE 64-bit cursor, so nothing is lost or out of bounds; only
# the RECORDED address is truncated. A truncated offset is always < the true
# one, hence always inside the live arena, so every bounds check and every
# row-count assertion passes. What changes is WHICH BYTES a key cell names:
#   * key EQUALITY compares the probe against another group's bytes, so a row
#     either joins the WRONG group or splits into a DUPLICATE group;
#   * the DRAIN emits those other bytes as the group's key.
# Both are silent wrong answers, and no value oracle keyed on the emitted rows
# can distinguish them from a correct run of a different query.
#
# The guard is in `reserve_var_bytes` — the one choke point all three writers
# (`write_slot_str`, `write_slot_str_from_byteview`,
# `write_slot_str_from_storage`) call before they read the cursor — so it
# refuses BEFORE the multi-GiB allocation the overflowing append would make.
# =============================================================================


from komira_engine_operators.column_format_storage import (
    ColumnFormatStorage,
    VAR_DESC_OFFSET_MAX,
    _var_desc_pack,
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_STRING,
    ROLE_KEY,
    ROLE_PAYLOAD,
)
from std.testing import assert_equal, assert_raises, assert_true


def _make_i64_string_layout() -> List[ColDescriptor]:
    """Layout: 2 cols, [I64-key, STRING-payload], no validity."""
    var layout = List[ColDescriptor]()
    layout.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    layout.append(
        ColDescriptor(
            name_id=1,
            kind=COL_VAR_STRING,
            dtype_tag=DT_STRING,
            role=ROLE_PAYLOAD,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return layout^


def test_reserve_past_the_offset_field_is_refused() raises:
    """A reservation whose resulting CURSOR would not fit the 32-bit offset
    field must RAISE, not silently truncate the descriptor it will write.

    ⚠ THE ASSERTION IS ON THE REFUSAL, NOT ON THE ALLOCATION. Before the
    guard this call did not raise — it went and allocated a 4 GiB arena and
    then handed out an offset the descriptor could not represent. So this test
    is also what keeps the refusal AHEAD of the allocation.
    """
    var layout = _make_i64_string_layout()
    var st = ColumnFormatStorage.alloc(layout^, 4)
    # var_idx 0 is the storage's only varlen col (col_idx_in_storage == 1).
    with assert_raises():
        st.reserve_var_bytes(0, 1 << 32)


def test_reserve_below_the_offset_field_is_admitted() raises:
    """The guard's other direction: an ordinary reservation still grows."""
    var layout = _make_i64_string_layout()
    var st = ColumnFormatStorage.alloc(layout^, 4)
    st.reserve_var_bytes(0, 64)
    var payload = List[UInt8]()
    for i in range(16):
        payload.append(UInt8(65 + i))
    st.write_slot_str(1, 0, payload)
    var back = st.read_slot_str_bytes(1, 0)
    assert_equal(len(back), 16)
    for i in range(16):
        assert_equal(Int(back[i]), 65 + i)
    assert_equal(st.var_bytes_used_for_col(1), 16)


def test_offset_ceiling_is_the_descriptor_field_width() raises:
    """The ceiling must be the UNSIGNED 32-bit field's width, not Arrow's
    SIGNED Int32 output ceiling.

    ⚠ THIS ASSERTION IS THE WHOLE POINT OF STATING THE CONSTANT. Two nearby
    numbers look interchangeable and are not: 2**32-1 = 4_294_967_295 is what
    `(offset & 0xFFFFFFFF)` can round-trip, and 2**31-1 = 2_147_483_647 is
    `ARROW_INT32_OFFSET_MAX`, a different field on a different side of the
    engine with its own (already-shipped) guard and its own promotion path.
    Setting this to the Arrow number would refuse 2 GiB of arena that the
    descriptor can address perfectly well; setting it to 2**32 would admit one
    unrepresentable cursor.
    """
    assert_equal(VAR_DESC_OFFSET_MAX, 4294967295)
    assert_equal(VAR_DESC_OFFSET_MAX, (1 << 32) - 1)


def test_desc_pack_round_trips_at_the_ceiling() raises:
    """The last representable offset packs and unpacks EXACTLY.

    Unpacked here the way every reader in the storage does it — `cell &
    0xFFFFFFFF` for the offset, `cell >> 32` for the length — so this pins the
    codec's two halves against each other, not just the packer against itself.
    """
    var cell = _var_desc_pack(VAR_DESC_OFFSET_MAX, VAR_DESC_OFFSET_MAX)
    assert_equal(Int(cell & UInt64(0xFFFFFFFF)), VAR_DESC_OFFSET_MAX)
    assert_equal(Int(cell >> 32), VAR_DESC_OFFSET_MAX)
    var ordinary = _var_desc_pack(1234567, 89)
    assert_equal(Int(ordinary & UInt64(0xFFFFFFFF)), 1234567)
    assert_equal(Int(ordinary >> 32), 89)


def test_desc_pack_refuses_an_offset_one_past_the_ceiling() raises:
    """⭐ THE SILENT WRONG ANSWER, PINNED AT THE EXACT SITE THAT PRODUCED IT.

    Before the guard this call RETURNED — with the offset masked down to 0, so
    the cell named the FIRST payload in the arena instead of the one just
    written. That is the corruption in one line: no raise, no out-of-range
    read, no row-count change, a different group's bytes.
    """
    with assert_raises():
        _ = _var_desc_pack(VAR_DESC_OFFSET_MAX + 1, 8)


def test_desc_pack_refuses_a_length_past_the_ceiling() raises:
    """The OTHER half of the cell wraps too, and it is the half nobody looks
    at: a payload of `2**32 + n` bytes records length `n`, so the reader
    silently truncates the VALUE rather than mis-addressing it."""
    with assert_raises():
        _ = _var_desc_pack(0, VAR_DESC_OFFSET_MAX + 1)


def test_desc_pack_refuses_a_negative_half() raises:
    """A negative offset or length is an upstream arithmetic bug, and masking
    it produces a plausible huge unsigned field rather than a diagnosis."""
    with assert_raises():
        _ = _var_desc_pack(-1, 8)
    with assert_raises():
        _ = _var_desc_pack(0, -1)


def test_reserve_boundary_is_exact_through_the_real_writer() raises:
    """⭐ THE EXACT EDGE, THROUGH THE CHOKE POINT AND THE WRITER — both sides
    of `need == 2**32 - 1`, which no other test here reaches.

    The tests above pin `reserve_var_bytes` only from `used == 0` against
    `1 << 32` (one past) and 64 (nowhere near), so a guard that refused ONE
    BYTE EARLY (`need >= VAR_DESC_OFFSET_MAX`) passed every one of them. This
    pins the admitted side at the last representable cursor and the refused
    side one byte later, then writes the LAST representable payload through
    the production writer and reads it back through the production reader.

    ⚠ THE 4 GiB ARENA IS VIRTUAL. `OwnedAlignedBuffer` allocates UNINITIALISED
    (`resize(unsafe_uninit_length=...)`) and `_grow_var_heap` copies only the
    `used` prefix, which is 0 at that point — so the one reserve that sizes
    the arena touches no page, and the one write touches only the last one.
    The cursor is then placed 8 bytes under the ceiling by assignment: the
    capacity already covers it, so nothing grows and nothing reads the
    skipped prefix.

    ⛔ AND IT PINS THAT A REFUSED WRITE MUTATES NOTHING: after the one-byte
    append past the ceiling raises, the cursor and the target slot's
    descriptor cell must be exactly what they were. A refusal that advanced
    the cursor, or wrote the cell, before raising would leave a caller that
    catches the raise holding a half-written slot.
    """
    var layout = _make_i64_string_layout()
    var st = ColumnFormatStorage.alloc(layout^, 4)
    st.reserve_var_bytes(0, VAR_DESC_OFFSET_MAX)
    assert_true(
        st.var_data_heaps[0].cap() >= VAR_DESC_OFFSET_MAX,
        "a reservation of exactly 2**32-1 bytes must be ADMITTED and sized",
    )
    st.var_data_used[0] = VAR_DESC_OFFSET_MAX - 8

    # need == 2**32 - 1: the last cursor both descriptor halves can carry.
    st.reserve_var_bytes(0, 8)
    # need == 2**32: one byte past it.
    with assert_raises():
        st.reserve_var_bytes(0, 9)

    var payload = List[UInt8]()
    for i in range(8):
        payload.append(UInt8(0x41 + i))
    st.write_slot_str(1, 0, payload)
    assert_equal(st.var_bytes_used_for_col(1), VAR_DESC_OFFSET_MAX)
    var stride = st.drain_str_stride(1)
    var cell = st.slot_str_cell(1, 0, stride)
    assert_equal(Int(cell & UInt64(0xFFFFFFFF)), VAR_DESC_OFFSET_MAX - 8)
    assert_equal(Int(cell >> 32), 8)
    var back = st.read_slot_str_bytes(1, 0)
    assert_equal(len(back), 8)
    for i in range(8):
        assert_equal(Int(back[i]), 0x41 + i)

    var cell1_before = st.slot_str_cell(1, 1, stride)
    var one = List[UInt8]()
    one.append(UInt8(0x5A))
    with assert_raises():
        st.write_slot_str(1, 1, one)
    assert_equal(
        st.var_bytes_used_for_col(1),
        VAR_DESC_OFFSET_MAX,
        "a REFUSED append must not advance the cursor",
    )
    assert_equal(
        st.slot_str_cell(1, 1, stride),
        cell1_before,
        "a REFUSED append must not write the target slot's descriptor",
    )
    # And the admitted cell at the edge is untouched by the refused one.
    assert_equal(st.slot_str_cell(1, 0, stride), cell)


def main() raises:
    test_reserve_past_the_offset_field_is_refused()
    test_reserve_below_the_offset_field_is_admitted()
    test_offset_ceiling_is_the_descriptor_field_width()
    test_desc_pack_round_trips_at_the_ceiling()
    test_desc_pack_refuses_an_offset_one_past_the_ceiling()
    test_desc_pack_refuses_a_length_past_the_ceiling()
    test_desc_pack_refuses_a_negative_half()
    test_reserve_boundary_is_exact_through_the_real_writer()
    print("test_var_heap_offset_ceiling: 8/8 PASS")
