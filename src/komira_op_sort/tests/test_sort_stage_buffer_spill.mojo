# =============================================================================
# SortBuffer spill and restore: the drain after a spill is the drain of the
# buffer that never spilled
# =============================================================================
#
# A composite (INT64, FLOAT64) key buffer with an INT64 payload is spilled to a
# local-disk spill storage (THSPLC chunks) and restored into the same buffer
# (the chunk ids live in the buffer that spilled): with two direction
# configurations, spilled again after a restore, and empty. Spill files go
# under $TEST_TMPDIR. `test_sort_stage_buffer_spill_order` covers feeding between
# spills.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_engine_runtime.spill.local_disk import LocalDiskSpillStorage
from komira_libc.posix import _read_env
from komira_op_sort.sort_stage_buffer import SortBuffer, SortKeyBlock
from komira_op_sort.sort_stage_columns import (
    SORT_DIR_ASC_U8,
    SORT_DIR_DESC_U8,
    SortKeyColumn_Typed,
)
from komira_op_sort.sort_stage_payloads import (
    PayloadCol_Typed,
    payload_column_i64,
)
from komira_op_sort.sort_stage_buffer import Payload_I64
from komira_op_sort.sort_stage_string_key import (
    sort_key_column_f64,
    sort_key_column_i64,
)


def _scratch_dir() raises -> String:
    """The directory this execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


# Composite (I64-key, F64-key) SortBuffer with an Int64 payload, fed by value
# (append_key / append_payload), so the column indices are a sentinel 0.
comptime _SortKB_I64F64 = SortKeyBlock[
    SortKeyColumn_Typed[DType.int64, 0], SortKeyColumn_Typed[DType.float64, 0]
]
comptime _SortBufI64F64 = SortBuffer[_SortKB_I64F64, Payload_I64]


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _temp_root(tag: String) raises -> String:
    """A unique directory under the scratch directory."""
    var pid = external_call["getpid", Int32]()
    return (
        (_scratch_dir() + String("/spill-sortbuf-"))
        + String(Int(pid))
        + String("-")
        + tag
    )


def _make_buffer(
    dir0_u8: UInt8, dir1_u8: UInt8
) -> _SortBufI64F64:
    """Construct an empty composite (I64, F64) SortBuffer with the given
    per-key directions, capacity 16."""
    var buf = _SortBufI64F64(
        _SortKB_I64F64((sort_key_column_i64(16), sort_key_column_f64(16))),
        (payload_column_i64(16),),
        16,
    )
    buf.set_direction(0, dir0_u8)
    buf.set_direction(1, dir1_u8)
    return buf^


def _feed_one(
    mut buf: _SortBufI64F64, k0: Int64, k1: Float64, payload: Int64
):
    """Feed one row: I64 key slot 0, F64 key slot 1, Int64 payload slot 0."""
    buf.append_key[0, DType.int64](k0)
    buf.append_key[1, DType.float64](k1)
    buf.append_payload[0, DType.int64](payload)
    buf.commit_row()


# The fixture rows. Deliberately include:
#   * duplicate (k0,k1) TIE rows (10, 1.5) at payloads 100 and 200 — stable
#     sort must keep them in buffer order (100 before 200).
#   * negative + zero key values.
#   * unsorted input so the drain genuinely reorders.
def _feed_fixture(mut buf: _SortBufI64F64):
    _feed_one(buf, Int64(10), Float64(1.5), Int64(100))
    _feed_one(buf, Int64(-3), Float64(9.0), Int64(101))
    _feed_one(buf, Int64(10), Float64(1.5), Int64(200))  # tie with row 0
    _feed_one(buf, Int64(0), Float64(-2.25), Int64(102))
    _feed_one(buf, Int64(7), Float64(3.5), Int64(103))
    _feed_one(buf, Int64(-3), Float64(9.0), Int64(104))  # tie with row 1
    _feed_one(buf, Int64(42), Float64(0.0), Int64(105))


comptime _FIXTURE_N: Int = 7


# -----------------------------------------------------------------------------
# Drain-equivalence helper: compare the stable-sorted output of two buffers.
# -----------------------------------------------------------------------------


def _assert_drain_equal(
    imm a: _SortBufI64F64, imm b: _SortBufI64F64
) raises:
    """Assert buffers `a` and `b` produce LOGICALLY IDENTICAL stable-sorted
    drains: same row count, and for each sorted position the same I64 key, F64
    key, and Int64 payload (ties included — stability is part of the contract).
    """
    var oa = a.sorted_order()
    var ob = b.sorted_order()
    assert_equal(len(oa), len(ob), "drain row-count mismatch")
    for pos in range(len(oa)):
        var ra = oa[pos]
        var rb = ob[pos]
        assert_equal(
            a.key_at[0, DType.int64](ra),
            b.key_at[0, DType.int64](rb),
            "I64 key mismatch at sorted pos " + String(pos),
        )
        assert_equal(
            a.key_at[1, DType.float64](ra),
            b.key_at[1, DType.float64](rb),
            "F64 key mismatch at sorted pos " + String(pos),
        )
        assert_equal(
            a.payload_at[0, DType.int64](ra),
            b.payload_at[0, DType.int64](rb),
            "payload mismatch at sorted pos " + String(pos),
        )


# =============================================================================
# Test 1 — round-trip: spill empties the buffer; restore reproduces the drain.
# =============================================================================


def test_sort_buffer_spill_restore_roundtrip() raises:
    var root = _temp_root("roundtrip")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    # Reference buffer (never spilled) — DESC on I64 key, ASC on F64 key.
    var ref_buf = _make_buffer(SORT_DIR_DESC_U8, SORT_DIR_ASC_U8)
    _feed_fixture(ref_buf)
    assert_equal(ref_buf.size(), _FIXTURE_N, "fixture row count")

    # Subject buffer (same shape + config) that we will spill + restore.
    var subj = _make_buffer(SORT_DIR_DESC_U8, SORT_DIR_ASC_U8)
    _feed_fixture(subj)

    # Pre-spill: resident, spillable, no chunks yet.
    assert_true(subj.can_spill(), "fresh buffer should be spillable")
    assert_true(
        subj.memory_usage_bytes() > Int64(0), "non-empty buffer has bytes"
    )
    assert_equal(storage.num_live_chunks(), 0, "no chunks before spill")

    # Spill: writes one THSPLC chunk + frees the in-memory buffers.
    var freed = subj.spill_to_storage(storage)
    assert_true(freed > Int64(0), "spill freed bytes")
    assert_equal(storage.num_live_chunks(), 1, "one live chunk after spill")
    assert_equal(subj.size(), 0, "buffer empty after spill")
    assert_equal(
        subj.memory_usage_bytes(), Int64(0), "no resident bytes after spill"
    )

    # Restore into the SAME subject (its directions config persists — config is
    # op-state, not spilled bytes). The restore re-feeds the buffer-order rows.
    subj.restore_from_storage(storage)
    assert_true(subj.can_spill(), "restored buffer spillable again")
    assert_equal(subj.size(), _FIXTURE_N, "row count restored")
    assert_equal(
        storage.num_live_chunks(),
        0,
        "chunk released after successful restore",
    )

    # The restored buffer's sorted drain must match the un-spilled reference,
    # byte-for-byte including the (10,1.5) tie ordering (100 before 200).
    _assert_drain_equal(ref_buf, subj)

    storage.cleanup()


# =============================================================================
# Test 2 — restore into the same buffer with the other direction pair.
# =============================================================================


def test_sort_buffer_spill_restore_same_buffer_asc_desc() raises:
    var root = _temp_root("ascdesc")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var ref_buf = _make_buffer(SORT_DIR_ASC_U8, SORT_DIR_DESC_U8)
    _feed_fixture(ref_buf)

    var subj = _make_buffer(SORT_DIR_ASC_U8, SORT_DIR_DESC_U8)
    _feed_fixture(subj)
    var freed = subj.spill_to_storage(storage)
    assert_true(freed > Int64(0), "spill freed bytes")

    subj.restore_from_storage(storage)
    _assert_drain_equal(ref_buf, subj)
    storage.cleanup()


# =============================================================================
# Test 3 — spill -> restore -> spill again (multi-pass chunk lifecycle).
# =============================================================================


def test_sort_buffer_spill_restore_spill_again() raises:
    var root = _temp_root("twopass")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var ref_buf = _make_buffer(SORT_DIR_DESC_U8, SORT_DIR_DESC_U8)
    _feed_fixture(ref_buf)

    var subj = _make_buffer(SORT_DIR_DESC_U8, SORT_DIR_DESC_U8)
    _feed_fixture(subj)

    # Pass 1.
    _ = subj.spill_to_storage(storage)
    assert_equal(storage.num_live_chunks(), 1, "pass-1 chunk live")
    subj.restore_from_storage(storage)
    assert_equal(storage.num_live_chunks(), 0, "pass-1 chunk released")
    _assert_drain_equal(ref_buf, subj)

    # Pass 2 — re-spill the restored buffer + restore once more.
    var freed2 = subj.spill_to_storage(storage)
    assert_true(freed2 > Int64(0), "pass-2 spill freed bytes")
    assert_equal(storage.num_live_chunks(), 1, "pass-2 chunk live")
    subj.restore_from_storage(storage)
    assert_equal(storage.num_live_chunks(), 0, "pass-2 chunk released")
    _assert_drain_equal(ref_buf, subj)

    storage.cleanup()


# =============================================================================
# Test 4 — empty buffer round-trip (0-row spill image).
# =============================================================================


def test_sort_buffer_spill_restore_empty() raises:
    var root = _temp_root("empty")
    var storage = LocalDiskSpillStorage.with_unlimited(root)

    var subj = _make_buffer(SORT_DIR_ASC_U8, SORT_DIR_ASC_U8)
    assert_equal(subj.size(), 0, "empty to start")
    assert_equal(
        subj.memory_usage_bytes(), Int64(0), "empty buffer has no bytes"
    )

    var freed = subj.spill_to_storage(storage)
    assert_equal(freed, Int64(0), "empty spill frees 0 bytes")
    assert_equal(storage.num_live_chunks(), 1, "empty chunk still written")

    subj.restore_from_storage(storage)
    assert_equal(subj.size(), 0, "still empty after restore")
    assert_equal(storage.num_live_chunks(), 0, "empty chunk released")

    storage.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
