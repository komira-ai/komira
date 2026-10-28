# =============================================================================
# test_key_bundle_var -- the key block `KeyBundleVar[*Keys]` and the per-arity
# free functions of `JoinBuildTable` (join_build_table_fns), N = 1..4
# =============================================================================
#
# What each section proves:
#   * construction: a key block of arity 1..6 (mixed DTypes included) starts
#     with every slot empty and reports its arity;
#   * insert + probe: each arity finds every inserted key, and a key that
#     differs in any one column misses;
#   * the duplicate flag and the M:N walk: equal keys each take a slot and
#     `join_build_probe_all_slots_N` returns all of them;
#   * the composite hash is the `key_combine` fold of the columns' `key_hash`;
#   * `rehash_keys_in_place` moves every column of a slot together;
#   * a table that grows past its first capacity still finds every key;
#   * prefetch is a hint that runs for present and absent keys;
#   * 50 build-and-drop cycles at arities 1, 4 and 6 (storage lifetimes).
# =============================================================================


from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_build_table_fns import (
    join_build_insert_slot_1,
    join_build_insert_slot_2,
    join_build_insert_slot_3,
    join_build_insert_slot_4,
    join_build_probe_1,
    join_build_probe_2,
    join_build_probe_3,
    join_build_probe_4,
    join_build_probe_all_slots_1,
    join_build_probe_all_slots_2,
    join_build_probe_all_slots_3,
    join_build_probe_all_slots_4,
    join_build_prefetch_key_1,
    join_build_prefetch_key_2,
    join_build_prefetch_key_3,
    join_build_prefetch_key_4,
)
from komira_op_join_stage.join_key_bundle import (
    KeyBundleVar,
    KeyBundle1,
    KeyBundle2,
    KeyBundle3,
    KeyBundle4,
    make_key_bundle_1,
    make_key_bundle_2,
    make_key_bundle_3,
    make_key_bundle_4,
)
from komira_op_join_stage.join_key_slot import (
    KeyBlockWrap,
    KeySlot,
    key_combine,
    key_hash,
    key_slot,
)
from komira_op_join_stage.join_payload_column import (
    PayloadBlock,
    PayloadSlot,
    payload_slot,
)
# =============================================================================
# §1 — Arity 1 construction
# =============================================================================


def test_v1_construct() raises:
    """Single-key variadic constructs cleanly + reports arity 1."""
    comptime I64 = DType.int64
    var bundle = make_key_bundle_1[I64](64)
    assert_equal(bundle.arity(), 1, "arity-1 reports 1")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")
    assert_true(bundle.slot_is_empty(32), "slot 32 empty")
    assert_true(bundle.slot_is_empty(63), "slot 63 empty")


def test_v1_construct_i32() raises:
    """Single-key variadic over non-I64 DType (Int32) constructs."""
    comptime I32 = DType.int32
    var bundle = make_key_bundle_1[I32](32)
    assert_equal(bundle.arity(), 1, "arity-1 I32 reports 1")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


# =============================================================================
# §2 — Arity 2 construction + per-column DType heterogeneity
# =============================================================================


def test_v2_construct() raises:
    """Composite-2 variadic constructs + per-column slot-empty queries."""
    comptime I64 = DType.int64
    var bundle = make_key_bundle_2[I64, I64](64)
    assert_equal(bundle.arity(), 2, "arity-2 reports 2")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


def test_v2_construct_mixed_dtype() raises:
    """Composite-2 with mixed DTypes (I32, I64) — per-column DType
    heterogeneity validated by the variadic shape."""
    comptime I32 = DType.int32
    comptime I64 = DType.int64
    var bundle = make_key_bundle_2[I32, I64](32)
    assert_equal(bundle.arity(), 2, "mixed-dtype arity-2 reports 2")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


# =============================================================================
# §3 — Arity 3 + 4 construction
# =============================================================================


def test_v3_construct() raises:
    comptime I64 = DType.int64
    var bundle = make_key_bundle_3[I64, I64, I64](64)
    assert_equal(bundle.arity(), 3, "arity-3 reports 3")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


def test_v4_construct() raises:
    """Composite-4 variadic constructs."""
    comptime I64 = DType.int64
    var bundle = make_key_bundle_4[I64, I64, I64, I64](64)
    assert_equal(bundle.arity(), 4, "arity-4 reports 4")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


# =============================================================================
# §4 — Arity 5 + 6 (no factory; the raw constructor)
# =============================================================================


def test_v5_construct() raises:
    """Arity 5 through the raw `KeyBundleVar(KeyBlockWrap(...))` constructor."""
    comptime I64 = DType.int64
    var bundle = KeyBundleVar[
        KeySlot[I64], KeySlot[I64], KeySlot[I64], KeySlot[I64], KeySlot[I64]
    ](
        KeyBlockWrap[
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
        ](
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
        )
    )
    assert_equal(bundle.arity(), 5, "arity-5 reports 5")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


def test_v6_construct() raises:
    """Arity 6 through the raw constructor."""
    comptime I64 = DType.int64
    var bundle = KeyBundleVar[
        KeySlot[I64],
        KeySlot[I64],
        KeySlot[I64],
        KeySlot[I64],
        KeySlot[I64],
        KeySlot[I64],
    ](
        KeyBlockWrap[
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
        ](
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
            key_slot[I64](32),
        )
    )
    assert_equal(bundle.arity(), 6, "arity-6 reports 6")
    assert_true(bundle.slot_is_empty(0), "slot 0 empty")


# =============================================================================
# §5 — Per-arity insert + probe (N = 1..4) through the free functions
# =============================================================================
#
# The free fns take `mut table: JoinBuildTable[...]`, so each test builds a
# small JBT with a single PayloadSlot[I64] payload column (the smallest non-zero
# payload arity — JBT's _at_load_factor + _maybe_grow are exercised by §10).


def _build_jbt_v1(capacity: Int) -> JoinBuildTable[
    KeyBundle1[DType.int64], PayloadSlot[DType.int64]
]:
    comptime I64 = DType.int64
    return JoinBuildTable[KeyBundle1[I64], PayloadSlot[I64]](
        make_key_bundle_1[I64](capacity),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](capacity)),
        capacity,
    )


def _build_jbt_v2(capacity: Int) -> JoinBuildTable[
    KeyBundle2[DType.int64, DType.int64], PayloadSlot[DType.int64]
]:
    comptime I64 = DType.int64
    return JoinBuildTable[KeyBundle2[I64, I64], PayloadSlot[I64]](
        make_key_bundle_2[I64, I64](capacity),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](capacity)),
        capacity,
    )


def _build_jbt_v3(capacity: Int) -> JoinBuildTable[
    KeyBundle3[DType.int64, DType.int64, DType.int64], PayloadSlot[DType.int64]
]:
    comptime I64 = DType.int64
    return JoinBuildTable[KeyBundle3[I64, I64, I64], PayloadSlot[I64]](
        make_key_bundle_3[I64, I64, I64](capacity),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](capacity)),
        capacity,
    )


def _build_jbt_v4(capacity: Int) -> JoinBuildTable[
    KeyBundle4[DType.int64, DType.int64, DType.int64, DType.int64],
    PayloadSlot[DType.int64],
]:
    comptime I64 = DType.int64
    return JoinBuildTable[KeyBundle4[I64, I64, I64, I64], PayloadSlot[I64]](
        make_key_bundle_4[I64, I64, I64, I64](capacity),
        PayloadBlock[PayloadSlot[I64]](payload_slot[I64](capacity)),
        capacity,
    )


def test_v1_insert_probe() raises:
    """Arity-1 free fns — insert several distinct keys, probe each back."""
    comptime I64 = DType.int64
    var table = _build_jbt_v1(64)

    var keys = List[Int64]()
    keys.append(Int64(10))
    keys.append(Int64(20))
    keys.append(Int64(30))
    keys.append(Int64(99))
    for i in range(len(keys)):
        var slot = join_build_insert_slot_1[I64, PayloadSlot[I64]](
            table, keys[i]
        )
        assert_true(slot >= 0, "insert slot >= 0")
    assert_equal(table.n_used, 4, "n_used == 4")
    assert_false(table.has_duplicate_keys, "no dup with distinct keys")

    for i in range(len(keys)):
        var s = join_build_probe_1[I64, PayloadSlot[I64]](table, keys[i])
        assert_true(s >= 0, "probe of inserted key hits")

    var miss = join_build_probe_1[I64, PayloadSlot[I64]](table, Int64(12345))
    assert_true(miss < 0, "probe of absent key misses")


def test_v2_insert_probe() raises:
    """Arity-2 free fns — composite-2 insert + per-column discriminator."""
    comptime I64 = DType.int64
    var table = _build_jbt_v2(64)

    var sa = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100)
    )
    var sb = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(20), Int64(200)
    )
    var sc = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(101)
    )
    assert_equal(table.n_used, 3, "n_used == 3")
    assert_false(
        table.has_duplicate_keys,
        "no exact-composite dup (key0 same, key1 differs)",
    )
    assert_true(sa != sb, "slot_a != slot_b")
    assert_true(sa != sc, "slot_a != slot_c")

    var h_10_100 = join_build_probe_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100)
    )
    assert_true(h_10_100 >= 0, "probe (10,100) hits")
    var m_10_200 = join_build_probe_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(200)
    )
    assert_true(m_10_200 < 0, "probe (10,200) misses — key1 discrim")
    var m_99_99 = join_build_probe_2[I64, I64, PayloadSlot[I64]](
        table, Int64(99), Int64(99)
    )
    assert_true(m_99_99 < 0, "probe (99,99) misses")


def test_v3_insert_probe() raises:
    """Arity-3 free fns — composite-3 insert + probe."""
    comptime I64 = DType.int64
    var table = _build_jbt_v3(64)

    _ = join_build_insert_slot_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3)
    )
    _ = join_build_insert_slot_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(4), Int64(5), Int64(6)
    )
    assert_equal(table.n_used, 2, "n_used == 2")

    var hit = join_build_probe_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3)
    )
    assert_true(hit >= 0, "probe (1,2,3) hits")
    var miss = join_build_probe_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(4)
    )
    assert_true(miss < 0, "probe (1,2,4) misses — key2 discrim")


def test_v4_insert_probe() raises:
    """Arity-4 free fns — composite-4 insert + probe ."""
    comptime I64 = DType.int64
    var table = _build_jbt_v4(64)

    _ = join_build_insert_slot_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), Int64(4)
    )
    _ = join_build_insert_slot_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(20), Int64(30), Int64(40)
    )
    assert_equal(table.n_used, 2, "n_used == 2")

    var hit = join_build_probe_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), Int64(4)
    )
    assert_true(hit >= 0, "probe (1,2,3,4) hits")
    var miss = join_build_probe_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), Int64(99)
    )
    assert_true(miss < 0, "probe (1,2,3,99) misses — key3 discrim")


def test_v1_duplicate_key_flag() raises:
    """Arity-1: inserting the same key twice flips the table's
    `has_duplicate_keys` flag."""
    comptime I64 = DType.int64
    var table = _build_jbt_v1(64)
    _ = join_build_insert_slot_1[I64, PayloadSlot[I64]](table, Int64(10))
    assert_false(table.has_duplicate_keys, "first insert sees no dup")
    _ = join_build_insert_slot_1[I64, PayloadSlot[I64]](table, Int64(10))
    assert_true(table.has_duplicate_keys, "second insert of same key flips")
    assert_equal(table.n_used, 2, "M:N — no dedupe")


# =============================================================================
# §6 — probe_all_slots M:N chain walk
# =============================================================================


def test_v1_probe_all_slots_m_to_n() raises:
    """Arity-1 — insert key=10 three times, probe_all_slots returns three
    slots."""
    comptime I64 = DType.int64
    var table = _build_jbt_v1(64)
    for _ in range(3):
        _ = join_build_insert_slot_1[I64, PayloadSlot[I64]](table, Int64(10))
    assert_equal(table.n_used, 3, "n_used == 3")

    var hits = List[Int]()
    join_build_probe_all_slots_1[I64, PayloadSlot[I64]](
        table, Int64(10), hits
    )
    assert_equal(len(hits), 3, "probe_all_slots returns 3 matches")


def test_v2_probe_all_slots_chain() raises:
    """Arity-2 — insert (10,100) twice + (10,200), probe (10,100) -> 2;
    probe (10,200) -> 1."""
    comptime I64 = DType.int64
    var table = _build_jbt_v2(64)
    _ = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100)
    )
    _ = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100)
    )
    _ = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(200)
    )

    var hits_100 = List[Int]()
    join_build_probe_all_slots_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100), hits_100
    )
    assert_equal(len(hits_100), 2, "(10,100) hits 2 slots")

    var hits_200 = List[Int]()
    join_build_probe_all_slots_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(200), hits_200
    )
    assert_equal(len(hits_200), 1, "(10,200) hits 1 slot")


def test_v3_probe_all_slots_chain() raises:
    """Arity-3 — composite-3 M:N walk."""
    comptime I64 = DType.int64
    var table = _build_jbt_v3(64)
    for _ in range(2):
        _ = join_build_insert_slot_3[I64, I64, I64, PayloadSlot[I64]](
            table, Int64(1), Int64(2), Int64(3)
        )

    var hits = List[Int]()
    join_build_probe_all_slots_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), hits
    )
    assert_equal(len(hits), 2, "(1,2,3) M:N chain returns 2")


def test_v4_probe_all_slots_chain() raises:
    """Arity-4 — composite-4 M:N walk."""
    comptime I64 = DType.int64
    var table = _build_jbt_v4(64)
    for _ in range(2):
        _ = join_build_insert_slot_4[I64, I64, I64, I64, PayloadSlot[I64]](
            table, Int64(1), Int64(2), Int64(3), Int64(4)
        )

    var hits = List[Int]()
    join_build_probe_all_slots_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), Int64(4), hits
    )
    assert_equal(len(hits), 2, "(1,2,3,4) M:N chain returns 2")


# =============================================================================
# §7 — Composite-hash combine rule
# =============================================================================


def test_v2_composite_hash_combine_rule() raises:
    """Compute the expected composite hash as the `key_combine` fold of the
    per-key `key_hash`es (from 0, in column order) and compare against `KeyBundleVar.slot_hash(s)` when
    both columns at slot `s` hold the stored key values."""
    comptime I64 = DType.int64
    var bundle = make_key_bundle_2[I64, I64](64)
    # Write directly via the typed accessor.
    bundle.cols[0].write_value(7, Int64(42))
    bundle.cols[1].write_value(7, Int64(99))

    var expected = key_combine(
        key_combine(0, key_hash[I64](Int64(42))), key_hash[I64](Int64(99))
    )
    var got = bundle.slot_hash(7)
    assert_equal(
        Int(got),
        Int(expected),
        "KeyBundleVar.slot_hash matches the combine fold of per-key hashes",
    )


def test_v3_composite_hash_combine_rule() raises:
    comptime I64 = DType.int64
    var bundle = make_key_bundle_3[I64, I64, I64](64)
    bundle.cols[0].write_value(3, Int64(11))
    bundle.cols[1].write_value(3, Int64(22))
    bundle.cols[2].write_value(3, Int64(33))

    var expected = key_combine(
        key_combine(
            key_combine(0, key_hash[I64](Int64(11))), key_hash[I64](Int64(22))
        ),
        key_hash[I64](Int64(33)),
    )
    var got = bundle.slot_hash(3)
    assert_equal(Int(got), Int(expected), "arity-3 combine fold matches")


def test_v4_composite_hash_combine_rule() raises:
    comptime I64 = DType.int64
    var bundle = make_key_bundle_4[I64, I64, I64, I64](64)
    bundle.cols[0].write_value(5, Int64(7))
    bundle.cols[1].write_value(5, Int64(8))
    bundle.cols[2].write_value(5, Int64(9))
    bundle.cols[3].write_value(5, Int64(10))

    var expected = key_combine(
        key_combine(
            key_combine(
                key_combine(0, key_hash[I64](Int64(7))),
                key_hash[I64](Int64(8)),
            ),
            key_hash[I64](Int64(9)),
        ),
        key_hash[I64](Int64(10)),
    )
    var got = bundle.slot_hash(5)
    assert_equal(Int(got), Int(expected), "arity-4 combine fold matches")


# =============================================================================
# §9 — rehash_keys_in_place (`_grow` path)
# =============================================================================


def test_rehash_keys_in_place_n3() raises:
    """Arity-3 rehash_keys_in_place — insert one row at cap=16, build a
    synthetic remap that moves the row to a known slot at new_cap=32, then
    verify the data lives at the new slot in every column (per-column
    lockstep)."""
    comptime I64 = DType.int64
    var bundle = make_key_bundle_3[I64, I64, I64](16)
    bundle.cols[0].write_value(0, Int64(7))
    bundle.cols[1].write_value(0, Int64(8))
    bundle.cols[2].write_value(0, Int64(9))
    # Bundle is now non-empty at slot 0.
    assert_false(bundle.slot_is_empty(0), "slot 0 non-empty pre-rehash")

    # Build remap: slot 0 -> slot 13, everything else -1.
    var remap = List[Int](capacity=16)
    remap.append(13)
    for _ in range(15):
        remap.append(-1)

    bundle.rehash_keys_in_place(32, remap)

    # After rehash: slot 13 should hold the data in EVERY column; slot 0
    # should be empty.
    assert_true(
        not bundle.slot_is_empty(13), "data at target slot 13"
    )
    assert_true(bundle.slot_is_empty(0), "source slot 0 empty after rehash")
    # Per-column lockstep verification — bundle's col k at slot 13 must
    # equal the originally-written value.
    assert_equal(
        Int(bundle.cols[0].slot_at(13)), 7, "col 0 at new slot 13"
    )
    assert_equal(
        Int(bundle.cols[1].slot_at(13)), 8, "col 1 at new slot 13"
    )
    assert_equal(
        Int(bundle.cols[2].slot_at(13)), 9, "col 2 at new slot 13"
    )


# =============================================================================
# §10 — JoinBuildTable `_grow` end-to-end at N=1
# =============================================================================


def test_jbt_v1_grow_end_to_end() raises:
    """Insert 80 distinct keys into a JBT initially sized at cap=64. The
    `_maybe_grow` 75% load factor will trigger at least one `_grow`. After
    insert, probe every key — all must hit. Exercises the full chain:
    KeyBundleVar.slot_hash + KeyBundleVar.rehash_keys_in_place +
    PayloadSlot.rehash_in_place + JoinBuildTable._grow."""
    comptime I64 = DType.int64
    var table = _build_jbt_v1(64)
    var keys = List[Int64]()
    for i in range(80):
        keys.append(Int64(i + 100))

    for i in range(len(keys)):
        _ = join_build_insert_slot_1[I64, PayloadSlot[I64]](table, keys[i])
    assert_equal(table.n_used, 80, "all 80 inserted")
    assert_true(
        table.capacity() >= 128, "capacity grew past 64 (>=128 after grow)"
    )

    for i in range(len(keys)):
        var s = join_build_probe_1[I64, PayloadSlot[I64]](table, keys[i])
        assert_true(s >= 0, "post-grow probe hits")


def test_jbt_v2_grow_end_to_end() raises:
    """Same as `test_jbt_v1_grow_end_to_end` at arity-2 — verify the
    composite-key path through `_grow` rehashes correctly across BOTH key
    columns AND the payload column in lockstep."""
    comptime I64 = DType.int64
    var table = _build_jbt_v2(64)
    for i in range(80):
        _ = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
            table, Int64(i + 1), Int64(i + 1000)
        )
    assert_equal(table.n_used, 80, "all 80 inserted at arity-2")
    assert_true(table.capacity() >= 128, "capacity grew")
    for i in range(80):
        var s = join_build_probe_2[I64, I64, PayloadSlot[I64]](
            table, Int64(i + 1), Int64(i + 1000)
        )
        assert_true(s >= 0, "post-grow probe hits")


# =============================================================================
# §10b — prefetch_key free fns (no-op hint, smoke test)
# =============================================================================
#
# `prefetch_at` is a non-faulting hint — the test verifies the call compiles
# + runs without fault. Bit-exact semantics are guaranteed by the formula
# match (combine fold of per-key hashes).


def test_v1_prefetch_key_smoke() raises:
    comptime I64 = DType.int64
    var table = _build_jbt_v1(64)
    _ = join_build_insert_slot_1[I64, PayloadSlot[I64]](table, Int64(42))
    # The prefetch helper is a hint — should run without fault for both
    # present and absent keys.
    join_build_prefetch_key_1[I64, PayloadSlot[I64]](table, Int64(42))
    join_build_prefetch_key_1[I64, PayloadSlot[I64]](table, Int64(99))


def test_v2_prefetch_key_smoke() raises:
    comptime I64 = DType.int64
    var table = _build_jbt_v2(64)
    _ = join_build_insert_slot_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100)
    )
    join_build_prefetch_key_2[I64, I64, PayloadSlot[I64]](
        table, Int64(10), Int64(100)
    )


def test_v3_prefetch_key_smoke() raises:
    comptime I64 = DType.int64
    var table = _build_jbt_v3(64)
    _ = join_build_insert_slot_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3)
    )
    join_build_prefetch_key_3[I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3)
    )


def test_v4_prefetch_key_smoke() raises:
    comptime I64 = DType.int64
    var table = _build_jbt_v4(64)
    _ = join_build_insert_slot_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), Int64(4)
    )
    join_build_prefetch_key_4[I64, I64, I64, I64, PayloadSlot[I64]](
        table, Int64(1), Int64(2), Int64(3), Int64(4)
    )


# =============================================================================
# §11 — build-and-drop stress (50 cycles at N=1, 4, 6)
# =============================================================================


def test_build_drop_stress_v1() raises:
    """50 build-and-drop cycles at arity 1."""
    comptime I64 = DType.int64
    for cycle in range(50):
        var table = _build_jbt_v1(32)
        var k = Int64(cycle + 1)
        _ = join_build_insert_slot_1[I64, PayloadSlot[I64]](table, k)
        var s = join_build_probe_1[I64, PayloadSlot[I64]](table, k)
        assert_true(s >= 0, "stress cycle v1 hit")


def test_build_drop_stress_v4() raises:
    """50 build-and-drop cycles at arity 4."""
    comptime I64 = DType.int64
    for cycle in range(50):
        var table = _build_jbt_v4(32)
        var k = Int64(cycle + 1)
        _ = join_build_insert_slot_4[I64, I64, I64, I64, PayloadSlot[I64]](
            table, k, k * 2, k * 3, k * 4
        )
        var s = join_build_probe_4[I64, I64, I64, I64, PayloadSlot[I64]](
            table, k, k * 2, k * 3, k * 4
        )
        assert_true(s >= 0, "stress cycle v4 hit")


def test_build_drop_stress_v6_bundle_only() raises:
    """50 build-and-drop cycles of an arity-6 key block."""
    comptime I64 = DType.int64
    for cycle in range(50):
        var bundle = KeyBundleVar[
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
            KeySlot[I64],
        ](
            KeyBlockWrap[
                KeySlot[I64],
                KeySlot[I64],
                KeySlot[I64],
                KeySlot[I64],
                KeySlot[I64],
                KeySlot[I64],
            ](
                key_slot[I64](32),
                key_slot[I64](32),
                key_slot[I64](32),
                key_slot[I64](32),
                key_slot[I64](32),
                key_slot[I64](32),
            )
        )
        assert_equal(bundle.arity(), 6, "arity-6 each cycle")
        assert_true(bundle.slot_is_empty(0), "slot 0 empty each cycle")
        # Write + read at slot 7 in each column. Pack-indexing requires
        # comptime indices, so the columns are spelled out (`@parameter for`
        # would also work, but explicit indexing keeps the assertions clear).
        bundle.cols[0].write_value(7, Int64(cycle + 0))
        bundle.cols[1].write_value(7, Int64(cycle + 1))
        bundle.cols[2].write_value(7, Int64(cycle + 2))
        bundle.cols[3].write_value(7, Int64(cycle + 3))
        bundle.cols[4].write_value(7, Int64(cycle + 4))
        bundle.cols[5].write_value(7, Int64(cycle + 5))
        # Verify per-column slot_at — confirms storage survives the cycle.
        assert_equal(
            Int(bundle.cols[0].slot_at(7)), cycle, "col 0 slot 7 round-trip"
        )
        assert_equal(
            Int(bundle.cols[5].slot_at(7)),
            cycle + 5,
            "col 5 slot 7 round-trip",
        )


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    var suite = TestSuite()
    # §1
    suite.test[test_v1_construct]()
    suite.test[test_v1_construct_i32]()
    # §2
    suite.test[test_v2_construct]()
    suite.test[test_v2_construct_mixed_dtype]()
    # §3
    suite.test[test_v3_construct]()
    suite.test[test_v4_construct]()
    # §4
    suite.test[test_v5_construct]()
    suite.test[test_v6_construct]()
    # §5
    suite.test[test_v1_insert_probe]()
    suite.test[test_v2_insert_probe]()
    suite.test[test_v3_insert_probe]()
    suite.test[test_v4_insert_probe]()
    suite.test[test_v1_duplicate_key_flag]()
    # §6
    suite.test[test_v1_probe_all_slots_m_to_n]()
    suite.test[test_v2_probe_all_slots_chain]()
    suite.test[test_v3_probe_all_slots_chain]()
    suite.test[test_v4_probe_all_slots_chain]()
    # §7
    suite.test[test_v2_composite_hash_combine_rule]()
    suite.test[test_v3_composite_hash_combine_rule]()
    suite.test[test_v4_composite_hash_combine_rule]()
    # §9
    suite.test[test_rehash_keys_in_place_n3]()
    # §10
    suite.test[test_jbt_v1_grow_end_to_end]()
    suite.test[test_jbt_v2_grow_end_to_end]()
    # §10b
    suite.test[test_v1_prefetch_key_smoke]()
    suite.test[test_v2_prefetch_key_smoke]()
    suite.test[test_v3_prefetch_key_smoke]()
    suite.test[test_v4_prefetch_key_smoke]()
    # §11
    suite.test[test_build_drop_stress_v1]()
    suite.test[test_build_drop_stress_v4]()
    suite.test[test_build_drop_stress_v6_bundle_only]()
    suite^.run()
