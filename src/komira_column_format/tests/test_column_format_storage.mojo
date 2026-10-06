# =============================================================================
# COL-UNTYPED-PHASE-C-G-1 — ColumnFormatStorage
# =============================================================================
#
# Tests the ColumnFormatStorage primitive published at
# an internal module (Phase C-G.1
# slot).
#
# Acceptance gates per dispatch:
#   (1) alloc + write_slot + read_slot_i64 for single I64 layout
#       (3 sub-tests min): single-cell, multi-cell, capacity boundary.
#   (2) alloc + write_slot + read_slot for composite-2 I64+F64 layout
#       (3 sub-tests min): cross-col isolation, per-DType round-trip,
#       interleaved write order.
#   (3) alloc + write_slot + read_slot_str for varlen STRING layout
#       (3 sub-tests min; Phase C-G.1 stub via List[UInt8] payload):
#       single payload, multi-slot, varying payload lengths.
#   (4) grow_to() doubles capacity correctly (1 sub-test): pre-grow
#       values preserved + new slots writable.
#
# Plus Phase C-G.1 specific:
#   - Validity bitmap helpers (set_slot_valid / is_slot_valid) — covers
#     the per-slot bit set/clear/read on a validity-tracked col.
#   - reserve_var_bytes auto-grows on overflow.
#
# Encapsulation invariants enforced indirectly: tests use ONLY the
# public surface (`alloc`, `write_slot_*`, `read_slot_*`,
# `read_slot_str_bytes`, `grow_to`, `set_slot_valid`, `is_slot_valid`,
# `set_n_slots`, `n_cols`, `col_descriptor`). No UnsafePointer / no
# wildcard origin / no unsafe_from_address.
# =============================================================================


from komira_column_format.column_format_storage import (
    ColumnFormatStorage,
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_F64,
    DT_STRING,
    ROLE_KEY,
    ROLE_PAYLOAD,
    ROLE_AGG_INPUT,
)
from std.testing import assert_equal, assert_true, assert_false, assert_almost_equal


# -----------------------------------------------------------------------------
# Fixture helpers — build per-layout ColDescriptor lists.
# -----------------------------------------------------------------------------


def _make_single_i64_layout() -> List[ColDescriptor]:
    """Layout: 1 col, I64, key, no validity."""
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
    return layout^


def _make_composite_i64_f64_layout() -> List[ColDescriptor]:
    """Layout: 2 cols, [I64-key, F64-payload], no validity."""
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
            kind=COL_FIXED,
            dtype_tag=DT_F64,
            role=ROLE_PAYLOAD,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return layout^


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


def _make_single_i64_validity_layout() -> List[ColDescriptor]:
    """Layout: 1 col, I64, agg-input, validity-tracked."""
    var layout = List[ColDescriptor]()
    layout.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_AGG_INPUT,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=True,
        )
    )
    return layout^


# -----------------------------------------------------------------------------
# Acceptance gate (1) — single I64 layout
# -----------------------------------------------------------------------------


def test_single_i64_single_cell_round_trip() raises:
    """alloc + write_slot_i64 + read_slot_i64 on a single (col=0,
    slot=0) cell."""
    var storage = ColumnFormatStorage.alloc(_make_single_i64_layout(), 16)
    assert_equal(storage.n_cols(), 1, "n_cols should be 1")
    assert_equal(storage.capacity, 16, "capacity should match alloc arg")
    assert_equal(storage.n_slots, 0, "n_slots should start at 0")
    storage.write_slot_i64(0, 0, Int64(42))
    storage.set_n_slots(1)
    assert_equal(
        Int(storage.read_slot_i64(0, 0)),
        42,
        "round-trip Int64(42) should yield 42",
    )


def test_single_i64_multi_cell_round_trip() raises:
    """write + read 10 distinct slots in a single I64 col; verify each
    cell holds its own value (no cross-slot contamination)."""
    var storage = ColumnFormatStorage.alloc(_make_single_i64_layout(), 16)
    var expected = List[Int64]()
    for s in range(10):
        var v = Int64(s * s - 100)  # spread + negative coverage
        storage.write_slot_i64(0, s, v)
        expected.append(v)
    storage.set_n_slots(10)
    for s in range(10):
        assert_equal(
            Int(storage.read_slot_i64(0, s)),
            Int(expected[s]),
            "slot " + String(s) + " mismatch",
        )


def test_single_i64_capacity_boundary() raises:
    """write to the last slot at capacity-1; verify read-back."""
    var storage = ColumnFormatStorage.alloc(_make_single_i64_layout(), 8)
    storage.write_slot_i64(0, 7, Int64(-9999))
    storage.set_n_slots(8)
    assert_equal(
        Int(storage.read_slot_i64(0, 7)),
        -9999,
        "boundary slot 7 round-trip",
    )
    assert_equal(storage.n_slots, 8, "n_slots after set_n_slots(8)")


# -----------------------------------------------------------------------------
# Acceptance gate (2) — composite-2 I64 + F64 layout
# -----------------------------------------------------------------------------


def test_composite_2_cross_col_isolation() raises:
    """write to col 0 and col 1; read-back of col 0 unaffected by col
    1 writes (cross-col buffers are independent)."""
    var storage = ColumnFormatStorage.alloc(
        _make_composite_i64_f64_layout(), 16
    )
    assert_equal(storage.n_cols(), 2, "n_cols should be 2")
    storage.write_slot_i64(0, 0, Int64(100))
    storage.write_slot_f64(1, 0, Float64(3.14))
    storage.set_n_slots(1)
    assert_equal(
        Int(storage.read_slot_i64(0, 0)),
        100,
        "col 0 round-trip",
    )
    assert_almost_equal(
        storage.read_slot_f64(1, 0),
        Float64(3.14),
        atol=1e-9,
        msg="col 1 round-trip",
    )


def test_composite_2_per_dtype_round_trip() raises:
    """4 slots across both cols; both DTypes round-trip independently."""
    var storage = ColumnFormatStorage.alloc(
        _make_composite_i64_f64_layout(), 16
    )
    var keys = List[Int64]()
    var vals = List[Float64]()
    keys.append(Int64(1))
    keys.append(Int64(2))
    keys.append(Int64(3))
    keys.append(Int64(-4))
    vals.append(Float64(1.5))
    vals.append(Float64(-2.5))
    vals.append(Float64(0.0))
    vals.append(Float64(1e10))
    for s in range(4):
        storage.write_slot_i64(0, s, keys[s])
        storage.write_slot_f64(1, s, vals[s])
    storage.set_n_slots(4)
    for s in range(4):
        assert_equal(
            Int(storage.read_slot_i64(0, s)),
            Int(keys[s]),
            "key slot " + String(s),
        )
        assert_almost_equal(
            storage.read_slot_f64(1, s),
            vals[s],
            atol=1e-9,
            msg="val slot " + String(s),
        )


def test_composite_2_interleaved_write_order() raises:
    """Writes interleaved (col 0 slot 5, col 1 slot 2, col 0 slot 3,
    ...) read back correctly. Validates per-(col, slot) addressing is
    independent of write order."""
    var storage = ColumnFormatStorage.alloc(
        _make_composite_i64_f64_layout(), 16
    )
    storage.write_slot_i64(0, 5, Int64(500))
    storage.write_slot_f64(1, 2, Float64(2.222))
    storage.write_slot_i64(0, 3, Int64(300))
    storage.write_slot_f64(1, 7, Float64(7.777))
    storage.write_slot_i64(0, 1, Int64(100))
    storage.set_n_slots(8)
    assert_equal(Int(storage.read_slot_i64(0, 5)), 500, "i64 slot 5")
    assert_equal(Int(storage.read_slot_i64(0, 3)), 300, "i64 slot 3")
    assert_equal(Int(storage.read_slot_i64(0, 1)), 100, "i64 slot 1")
    assert_almost_equal(
        storage.read_slot_f64(1, 2), Float64(2.222), atol=1e-9, msg="f64 slot 2"
    )
    assert_almost_equal(
        storage.read_slot_f64(1, 7), Float64(7.777), atol=1e-9, msg="f64 slot 7"
    )


# -----------------------------------------------------------------------------
# Acceptance gate (3) — varlen STRING layout (Phase C-G.1 stub via List[UInt8])
# -----------------------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] payload. Phase C-G.1 stub —
    Phase C-G.2 will replace this with `BatchView.col_str(...)` once
    STRINGCOLUMNVIEW-SUBSTRATE-V04 lands."""
    var out = List[UInt8]()
    for i in range(s.byte_length()):
        out.append(s.unsafe_ptr()[i])
    return out^


def test_varlen_string_single_payload() raises:
    """single STRING payload at (col=1, slot=0) round-trips through
    the var-data heap + 8B descriptor cell."""
    var storage = ColumnFormatStorage.alloc(_make_i64_string_layout(), 16)
    storage.write_slot_i64(0, 0, Int64(7))
    storage.write_slot_str(1, 0, _bytes("hello"))
    storage.set_n_slots(1)
    assert_equal(Int(storage.read_slot_i64(0, 0)), 7, "key slot 0")
    var got = storage.read_slot_str_bytes(1, 0)
    var want = _bytes("hello")
    assert_equal(got.__len__(), want.__len__(), "payload length")
    for i in range(want.__len__()):
        assert_equal(
            Int(got[i]),
            Int(want[i]),
            "payload byte " + String(i),
        )


def test_varlen_string_multi_slot() raises:
    """4 STRING payloads at distinct slots; each round-trips via the
    8B descriptor + per-slot offset arithmetic."""
    var storage = ColumnFormatStorage.alloc(_make_i64_string_layout(), 16)
    var payloads = List[String]()
    payloads.append(String("alpha"))
    payloads.append(String("beta"))
    payloads.append(String("gamma"))
    payloads.append(String("delta"))
    for s in range(4):
        storage.write_slot_i64(0, s, Int64(s))
        storage.write_slot_str(1, s, _bytes(payloads[s]))
    storage.set_n_slots(4)
    for s in range(4):
        assert_equal(Int(storage.read_slot_i64(0, s)), s, "key slot " + String(s))
        var got = storage.read_slot_str_bytes(1, s)
        var want = _bytes(payloads[s])
        assert_equal(
            got.__len__(),
            want.__len__(),
            "slot " + String(s) + " length",
        )
        for i in range(want.__len__()):
            assert_equal(
                Int(got[i]),
                Int(want[i]),
                "slot " + String(s) + " byte " + String(i),
            )


def test_varlen_string_varying_payload_lengths() raises:
    """Mix of short / medium / longer payloads; var-heap grows on
    demand. Validates reserve_var_bytes auto-grow path."""
    var storage = ColumnFormatStorage.alloc(_make_i64_string_layout(), 8)
    # Pre-empt the var heap into a small initial size by allocating a
    # tiny initial_capacity (8 * 16 = 128B), then write payloads that
    # cumulatively exceed 128B.
    var payloads = List[String]()
    payloads.append(String("a"))                                  # 1B
    payloads.append(String("longer string payload here"))         # 26B
    payloads.append(String("xy"))                                 # 2B
    payloads.append(String(
        "much longer payload bytes that force var-heap regrow past initial"
    ))                                                            # 64B
    payloads.append(String("z"))                                  # 1B
    for s in range(5):
        storage.write_slot_str(1, s, _bytes(payloads[s]))
    storage.set_n_slots(5)
    for s in range(5):
        var got = storage.read_slot_str_bytes(1, s)
        var want = _bytes(payloads[s])
        assert_equal(
            got.__len__(),
            want.__len__(),
            "slot " + String(s) + " length",
        )
        for i in range(want.__len__()):
            assert_equal(
                Int(got[i]),
                Int(want[i]),
                "slot " + String(s) + " byte " + String(i),
            )


# -----------------------------------------------------------------------------
# Acceptance gate (4) — grow_to() doubles capacity + preserves live cells
# -----------------------------------------------------------------------------


def test_grow_to_doubles_capacity_preserves_live() raises:
    """alloc(16) -> write 8 slots -> grow_to(32). Verify the 8 pre-grow
    values are still readable AND the new slots [8..32) are writable."""
    var storage = ColumnFormatStorage.alloc(_make_single_i64_layout(), 16)
    # Pre-grow: write 8 slots, set n_slots = 8.
    for s in range(8):
        storage.write_slot_i64(0, s, Int64(s * 10))
    storage.set_n_slots(8)
    assert_equal(storage.capacity, 16, "pre-grow capacity")
    # Grow to 32 — should preserve the 8 live cells.
    storage.grow_to(32)
    assert_equal(storage.capacity, 32, "post-grow capacity should be 32")
    assert_equal(storage.n_slots, 8, "n_slots should be unchanged")
    # Read-back of pre-grow cells.
    for s in range(8):
        assert_equal(
            Int(storage.read_slot_i64(0, s)),
            s * 10,
            "pre-grow slot " + String(s) + " preserved",
        )
    # New slots [8..32) are writable.
    for s in range(8, 32):
        storage.write_slot_i64(0, s, Int64(s * 100))
    storage.set_n_slots(32)
    for s in range(8, 32):
        assert_equal(
            Int(storage.read_slot_i64(0, s)),
            s * 100,
            "new slot " + String(s),
        )
    # Pre-grow slots STILL correct after writing new slots.
    for s in range(8):
        assert_equal(
            Int(storage.read_slot_i64(0, s)),
            s * 10,
            "pre-grow slot " + String(s) + " still preserved",
        )


# -----------------------------------------------------------------------------
# Validity bitmap helpers
# -----------------------------------------------------------------------------


def test_validity_set_and_read() raises:
    """set_slot_valid + is_slot_valid round-trip on a validity-tracked col,
    and the ALL-VALID allocation default.

    ⚠ THE DEFAULT FLIPPED and this assertion moved with it. It used
    to read `assert_false(..., "freshly allocated validity bit should be 0")`,
    describing the zero fill as an incidental property of the allocation. It
    is now a stated invariant in the other direction: a freshly allocated slot
    reads VALID, so that ABSENT INFORMATION MEANS VALID — the same convention
    `test_validity_non_tracked_col_always_valid` below already pins for a
    NON-tracked col, and Arrow's own.

    WHY IT HAD TO CHANGE. A slot's key cell is written by one of several
    writers and only two of them speak about validity (`_encode_key_cell`,
    `_copy_key_cell_storage`); the untyped agg's vectorised / monomorphised /
    dense-code key writers write BYTES ONLY, because they run only on a batch
    proven to hold no null key. While the fast folds declined on DECLARED
    nullability those writers never touched a tracked column. Once the gate
    became OBSERVED nullability they do — and under a zero default every group
    they insert would have DRAINED AS NULL, with the group count and every
    aggregate still exactly right, so no total would have shown it. See
    `ColumnFormatStorage.alloc`.

    The negative cases below now clear their bits explicitly, so the set/read
    round trip, the both-ways toggle and the byte-boundary coverage are
    unchanged."""
    var storage = ColumnFormatStorage.alloc(
        _make_single_i64_validity_layout(), 16
    )
    for s in range(16):
        assert_true(
            storage.is_slot_valid(0, s),
            "freshly allocated validity bit should be VALID, slot "
            + String(s),
        )
    # Clear everything first, so the assertions below still discriminate.
    for s in range(16):
        storage.set_slot_valid(0, s, False)
    assert_false(
        storage.is_slot_valid(0, 0), "explicitly cleared bit reads NULL"
    )
    storage.set_slot_valid(0, 0, True)
    storage.set_slot_valid(0, 3, True)
    storage.set_slot_valid(0, 7, True)
    storage.set_slot_valid(0, 9, True)
    assert_true(storage.is_slot_valid(0, 0), "slot 0 set True")
    assert_false(storage.is_slot_valid(0, 1), "slot 1 unset")
    assert_false(storage.is_slot_valid(0, 2), "slot 2 unset")
    assert_true(storage.is_slot_valid(0, 3), "slot 3 set True")
    assert_false(storage.is_slot_valid(0, 4), "slot 4 unset")
    assert_true(storage.is_slot_valid(0, 7), "slot 7 set True (byte boundary)")
    assert_false(storage.is_slot_valid(0, 8), "slot 8 unset (new byte)")
    assert_true(storage.is_slot_valid(0, 9), "slot 9 set True")
    # Toggle slot 0 back to False.
    storage.set_slot_valid(0, 0, False)
    assert_false(storage.is_slot_valid(0, 0), "slot 0 cleared back to False")

    # GROW preserves every written bit and defaults only the NEW slots. From
    # above, 3 / 7 / 9 are True and 0 / 1 / 2 / 4 / 8 are False; slots
    # [16, 64) have never been written. A grow that re-defaulted the live
    # prefix would silently un-NULL every existing NULL group.
    storage.set_n_slots(16)
    storage.grow_to(64)
    assert_true(storage.is_slot_valid(0, 3), "slot 3 survives grow as True")
    assert_false(storage.is_slot_valid(0, 4), "slot 4 survives grow as False")
    assert_false(storage.is_slot_valid(0, 8), "slot 8 survives grow as False")
    assert_true(storage.is_slot_valid(0, 9), "slot 9 survives grow as True")
    for s in range(16, 64):
        assert_true(
            storage.is_slot_valid(0, s),
            "grown-into slot " + String(s) + " defaults VALID",
        )


def test_validity_non_tracked_col_always_valid() raises:
    """Non-validity-tracked col returns True for is_slot_valid (matches
    Arrow no-null fast-path convention)."""
    var storage = ColumnFormatStorage.alloc(_make_single_i64_layout(), 16)
    # Single I64 layout is NOT validity-tracked.
    for s in range(16):
        assert_true(
            storage.is_slot_valid(0, s),
            "non-tracked col slot " + String(s) + " should report valid",
        )


# -----------------------------------------------------------------------------
# S2-VARGROW4 — the var-heap ladder ACROSS the 4x growth floor
# -----------------------------------------------------------------------------


def test_var_heap_growth_across_quad_floor_preserves_every_payload() raises:
    """Write past `VAR_HEAP_QUAD_GROWTH_FLOOR_BYTES` and read EVERY payload
    back byte-exact.

    ⛔ WHY THIS EXISTS AND WHAT IT WOULD CATCH. `_grow_var_heap` chooses the
    new capacity from `cur_cap`, then copies exactly `used` bytes forward. The
    S2-VARGROW4 floor adds a SECOND capacity arm, and the failure mode of a
    wrong one is not a crash: `reserve_var_bytes` would return having made too
    little room and the next payload would be written past the live region,
    silently corrupting a GROUP KEY. The other capacity arm (`new_cap <
    needed`) then hides it for every payload that happens to fit.

    ⚠ THE PAYLOADS MUST DIFFER FROM EACH OTHER AND FROM THEIR NEIGHBOURS. A
    constant payload reads back correctly out of a WRONG offset, so a fill of
    one repeated string is green against a broken copy-forward. Each slot here
    carries its own slot number in its bytes, at BOTH ends, so a payload read
    from the wrong place, truncated, or overlapped by the next one is a
    different byte sequence.

    Scale: 1 MiB is the floor, so the loop must move more than that through
    the heap to reach the new arm at all. 6,000 slots x ~200 B is ~1.2 MB,
    which crosses it and takes the 4x arm at least once.
    """
    var n_slots = 6000
    var storage = ColumnFormatStorage.alloc(_make_i64_string_layout(), n_slots)
    for s in range(n_slots):
        storage.write_slot_str(1, s, _vargrow_payload(s))
    storage.set_n_slots(n_slots)
    # The heap must actually have crossed the floor, or this test is vacuous
    # and would stay green with the new arm deleted.
    var used = storage.var_bytes_used_for_col(1)
    assert_true(
        used > (1 << 20),
        "VACUOUS: var heap used "
        + String(used)
        + " B never reached the 1 MiB quad-growth floor",
    )
    for s in range(n_slots):
        var got = storage.read_slot_str_bytes(1, s)
        var want = _vargrow_payload(s)
        assert_equal(
            got.__len__(), want.__len__(), "slot " + String(s) + " length"
        )
        for i in range(want.__len__()):
            assert_equal(
                Int(got[i]),
                Int(want[i]),
                "slot " + String(s) + " byte " + String(i),
            )


def _vargrow_payload(s: Int) -> List[UInt8]:
    """A per-slot payload that is unique, self-identifying at BOTH ends, and
    of a length that VARIES with the slot — so neither a constant-fill nor a
    fixed-stride read can satisfy it.

    Built as bytes rather than via `String` concatenation: this is called
    12,000 times and a quadratic `+=` ladder would dominate the test's wall
    without testing anything."""
    var out = List[UInt8]()
    # 4 little-endian tag bytes, then a slot-dependent body length, then the
    # same 4 tag bytes again.
    for k in range(4):
        out.append(UInt8((s >> (8 * k)) & 0xFF))
    var pad = 160 + (s % 97)
    for j in range(pad):
        out.append(UInt8(65 + ((s + j) % 26)))
    for k in range(4):
        out.append(UInt8((s >> (8 * k)) & 0xFF))
    return out^


# -----------------------------------------------------------------------------
# main — registry
# -----------------------------------------------------------------------------


def main() raises:
    # Gate 1 — single I64 (3 sub-tests).
    test_single_i64_single_cell_round_trip()
    test_single_i64_multi_cell_round_trip()
    test_single_i64_capacity_boundary()
    # Gate 2 — composite-2 I64+F64 (3 sub-tests).
    test_composite_2_cross_col_isolation()
    test_composite_2_per_dtype_round_trip()
    test_composite_2_interleaved_write_order()
    # Gate 3 — varlen STRING (3 sub-tests; Phase C-G.1 stub).
    test_varlen_string_single_payload()
    test_varlen_string_multi_slot()
    test_varlen_string_varying_payload_lengths()
    # Gate 4 — grow_to() (1 sub-test).
    test_grow_to_doubles_capacity_preserves_live()
    # Validity bitmap (bonus coverage; Phase C-G.1 scaffolding).
    test_validity_set_and_read()
    test_validity_non_tracked_col_always_valid()
    # S2-VARGROW4 — the 4x growth arm above the 1 MiB floor.
    test_var_heap_growth_across_quad_floor_preserves_every_payload()
    print("test_column_format_storage: 12/12 PASS")
