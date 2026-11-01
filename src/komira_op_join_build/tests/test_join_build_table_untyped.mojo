# =============================================================================
# test_join_build_table_untyped -- `JoinBuildTable_Untyped` build and probe
# (the directory itself: `test_hash_directory`)
# =============================================================================
#
# What it covers:
#   (1) single I64 key + 1 payload all-match (3 sub-tests min)
#   (2) composite-2 I64+I64 key + 3 payloads partial match (3 sub-tests min)
#   (3) mixed-DType keys, STRING included.
#   (4) empty BUILD (1 sub-test) — probe-only over an empty build
#       returns 0 match pairs.
#   (5) large 1000-row stress (1 sub-test) — full build + probe
#       round-trip across capacity-grow boundaries.
#
# Plus bonus coverage:
#   - has_duplicate_keys flag set on collision.
#   - Capacity grow correctness (write keys past initial_capacity).
#
# Encapsulation: tests use ONLY the public surface — no UnsafePointer,
# no wildcard origin, no unsafe_from_address.
# =============================================================================


from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_F64,
    DT_I32,
    DT_STRING,
    ROLE_KEY,
    ROLE_PAYLOAD,
)
from komira_op_join_build.join_build_untyped import (
    JoinBuildTable_Untyped,
    MatchPair,
)
from komira_arrow.batch_view import BatchView

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_arrow.string_array import StringArray

from std.testing import TestSuite, assert_equal, assert_true, assert_false


# -----------------------------------------------------------------------------
# Fixture helpers — build per-layout ColDescriptor lists + test
# RecordBatches.
# -----------------------------------------------------------------------------


def _make_single_i64_key() -> List[ColDescriptor]:
    """key_descriptors layout: 1 col, I64, key. col_idx_in_storage=0."""
    var l = List[ColDescriptor]()
    l.append(
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
    return l^


def _make_single_i64_payload(n_keys: Int) -> List[ColDescriptor]:
    """payload_descriptors layout: 1 col, I64, payload. col_idx_in_storage
    starts at n_keys (so the combined storage layout is contiguous)."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=10,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_PAYLOAD,
            col_idx_in_batch=1,
            col_idx_in_storage=n_keys,
            validity_tracked=False,
        )
    )
    return l^


def _make_composite_2_i64_key() -> List[ColDescriptor]:
    """key_descriptors layout: 2 cols, I64+I64, both keys."""
    var l = List[ColDescriptor]()
    l.append(
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
    l.append(
        ColDescriptor(
            name_id=1,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_KEY,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return l^


def _make_3_payload_i64(n_keys: Int) -> List[ColDescriptor]:
    """payload_descriptors layout: 3 cols, I64. col_idx_in_storage starts
    at n_keys. col_idx_in_batch starts at n_keys (assumes the batch has
    keys first, payloads after)."""
    var l = List[ColDescriptor]()
    for i in range(3):
        l.append(
            ColDescriptor(
                name_id=10 + i,
                kind=COL_FIXED,
                dtype_tag=DT_I64,
                role=ROLE_PAYLOAD,
                col_idx_in_batch=n_keys + i,
                col_idx_in_storage=n_keys + i,
                validity_tracked=False,
            )
        )
    return l^


def _make_string_key_stub() -> List[ColDescriptor]:
    """key_descriptors with a STRING varlen key (STUB acceptance gate)."""
    var l = List[ColDescriptor]()
    l.append(
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
    l.append(
        ColDescriptor(
            name_id=1,
            kind=COL_VAR_STRING,
            dtype_tag=DT_STRING,
            role=ROLE_KEY,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return l^


# -----------------------------------------------------------------------------
# Tiny Int64 RecordBatch helpers — match the in-tree
# `tests/engine/test_stage_join_build_arm.mojo:143-203` pattern using
# the public `RecordBatchBuilder` + `Column.from_primitive` + `PrimitiveArray`
# surface.
# -----------------------------------------------------------------------------


def _build_recordbatch_i64(values: List[Int64]) raises -> RecordBatch:
    """Build a 1-col RecordBatch holding Int64 values."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c0"), ArrowType.INT64, False))
    var schema = sb.build()
    var l: List[Scalar[DType.int64]] = []
    for i in range(values.__len__()):
        l.append(values[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(l))
    )
    return rbb.build(schema^)


def _build_recordbatch_i64_2(
    k0: List[Int64], k1: List[Int64]
) raises -> RecordBatch:
    """Build a 2-col RecordBatch with two Int64 columns."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c0"), ArrowType.INT64, False))
    sb.add_field(Field(String("c1"), ArrowType.INT64, False))
    var schema = sb.build()
    var l0: List[Scalar[DType.int64]] = []
    var l1: List[Scalar[DType.int64]] = []
    for i in range(k0.__len__()):
        l0.append(k0[i])
        l1.append(k1[i])
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(l0))
    )
    rbb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(l1))
    )
    return rbb.build(schema^)


def _build_recordbatch_i64_n(cols_values: List[List[Int64]]) raises -> RecordBatch:
    """Build an N-col RecordBatch with N Int64 columns. All cols must
    have the same length (caller invariant)."""
    var n_cols = cols_values.__len__()
    var sb = SchemaBuilder()
    for i in range(n_cols):
        sb.add_field(Field(String("c") + String(i), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(n_cols)
    for c in range(n_cols):
        var l: List[Scalar[DType.int64]] = []
        for r in range(cols_values[c].__len__()):
            l.append(cols_values[c][r])
        rbb.add_column(
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(l)
            )
        )
    return rbb.build(schema^)


# =============================================================================
# Acceptance gate (1) — single I64 key + 1 I64 payload — all-match
# =============================================================================


def test_single_i64_key_payload_build_size() raises:
    """After build with 3 unique keys, n_slots == 3."""
    var jbt = JoinBuildTable_Untyped(
        _make_single_i64_key(), _make_single_i64_payload(1), 16
    )

    var keys: List[Int64] = [100, 200, 300]
    var payloads: List[Int64] = [1000, 2000, 3000]
    var cols = List[List[Int64]]()
    cols.append(keys^)
    cols.append(payloads^)
    var build_rb = _build_recordbatch_i64_n(cols)
    var build_bv = BatchView(build_rb)
    jbt.build_batch(build_bv)

    assert_equal(jbt.n_slots(), 3, "n_slots after 3 unique keys")
    assert_equal(jbt.n_keys(), 1, "n_keys for single-i64 layout")
    assert_equal(jbt.n_payload(), 1, "n_payload for single payload")
    assert_false(jbt.has_duplicate_keys, "no duplicates on unique build")


def test_single_i64_key_probe_all_match() raises:
    """Probe with all-matching keys yields 3 MatchPairs + correct
    payload gather."""
    var jbt = JoinBuildTable_Untyped(
        _make_single_i64_key(), _make_single_i64_payload(1), 16
    )

    var build_keys: List[Int64] = [7, 11, 13]
    var build_payload: List[Int64] = [70, 110, 130]
    var cols = List[List[Int64]]()
    cols.append(build_keys^)
    cols.append(build_payload^)
    var build_rb = _build_recordbatch_i64_n(cols)
    var build_bv = BatchView(build_rb)
    jbt.build_batch(build_bv)

    # Probe with the same keys (all-match).
    var probe_keys: List[Int64] = [7, 11, 13]
    var probe_rb = _build_recordbatch_i64(probe_keys)
    var probe_bv = BatchView(probe_rb)
    var matches = List[MatchPair]()
    jbt.probe_batch(probe_bv, matches)

    assert_equal(matches.__len__(), 3, "should match all 3 rows")
    # Validate output payload gather.
    var gathered = jbt.read_payload_i64_for(matches, 0)
    assert_equal(gathered.__len__(), 3, "payload gather has 3 entries")
    # Row r -> probe_keys[r] -> matches[r].build_slot -> build_payload[slot]
    # since the build inserted in order (key 7 -> slot 0 -> payload 70, etc.).
    assert_equal(Int(gathered[0]), 70, "row 0 -> payload 70")
    assert_equal(Int(gathered[1]), 110, "row 1 -> payload 110")
    assert_equal(Int(gathered[2]), 130, "row 2 -> payload 130")


def test_single_i64_key_probe_partial_match_and_misses() raises:
    """Probe with some matching + some non-matching keys yields only
    matching MatchPairs (no entries for misses)."""
    var jbt = JoinBuildTable_Untyped(
        _make_single_i64_key(), _make_single_i64_payload(1), 16
    )

    var build_keys: List[Int64] = [1, 2, 3]
    var build_payload: List[Int64] = [100, 200, 300]
    var cols = List[List[Int64]]()
    cols.append(build_keys^)
    cols.append(build_payload^)
    var build_rb = _build_recordbatch_i64_n(cols)
    jbt.build_batch(BatchView(build_rb))

    # Probe: keys [2, 99, 3, 88, 1] — 3 match, 2 miss.
    var probe_keys: List[Int64] = [2, 99, 3, 88, 1]
    var probe_rb = _build_recordbatch_i64(probe_keys)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)

    assert_equal(matches.__len__(), 3, "should match 3 out of 5 rows")
    # Verify the matches reference the correct probe_row indices.
    assert_equal(matches[0].probe_row, 0, "probe row 0 (key 2) matched")
    assert_equal(matches[1].probe_row, 2, "probe row 2 (key 3) matched")
    assert_equal(matches[2].probe_row, 4, "probe row 4 (key 1) matched")
    # Verify gathered payloads are correct.
    var gathered = jbt.read_payload_i64_for(matches, 0)
    assert_equal(Int(gathered[0]), 200, "key 2 -> payload 200")
    assert_equal(Int(gathered[1]), 300, "key 3 -> payload 300")
    assert_equal(Int(gathered[2]), 100, "key 1 -> payload 100")


# =============================================================================
# Acceptance gate (2) — composite-2 I64+I64 key + 3 I64 payloads
# =============================================================================


def test_composite_2_key_3_payload_build_size() raises:
    """Composite-2 key with no duplicates -> n_slots == n_rows."""
    var jbt = JoinBuildTable_Untyped(
        _make_composite_2_i64_key(), _make_3_payload_i64(2), 16
    )

    # 4 unique (k0, k1) tuples.
    var k0: List[Int64] = [1, 1, 2, 2]
    var k1: List[Int64] = [10, 20, 10, 20]
    var p0: List[Int64] = [1010, 1020, 2010, 2020]
    var p1: List[Int64] = [1011, 1021, 2011, 2021]
    var p2: List[Int64] = [1012, 1022, 2012, 2022]
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    cols.append(p0^)
    cols.append(p1^)
    cols.append(p2^)
    var rb = _build_recordbatch_i64_n(cols)
    jbt.build_batch(BatchView(rb))

    assert_equal(jbt.n_slots(), 4, "4 distinct (k0,k1) tuples")
    assert_equal(jbt.n_keys(), 2, "composite-2 key arity")
    assert_equal(jbt.n_payload(), 3, "3 payload cols")
    assert_false(jbt.has_duplicate_keys, "no dupes in build")


def test_composite_2_key_3_payload_partial_match() raises:
    """Composite-2 probe with partial overlap yields the correct
    MatchPair count + all 3 payload gathers are consistent."""
    var jbt = JoinBuildTable_Untyped(
        _make_composite_2_i64_key(), _make_3_payload_i64(2), 16
    )

    # Build: 3 keys [(1,10), (2,20), (3,30)].
    var bk0: List[Int64] = [1, 2, 3]
    var bk1: List[Int64] = [10, 20, 30]
    var bp0: List[Int64] = [100, 200, 300]
    var bp1: List[Int64] = [101, 201, 301]
    var bp2: List[Int64] = [102, 202, 302]
    var cols = List[List[Int64]]()
    cols.append(bk0^)
    cols.append(bk1^)
    cols.append(bp0^)
    cols.append(bp1^)
    cols.append(bp2^)
    var build_rb = _build_recordbatch_i64_n(cols)
    jbt.build_batch(BatchView(build_rb))

    # Probe: 4 keys — [(2,20) match, (1,99) miss because k1!=10,
    # (3,30) match, (99,99) miss].
    var pk0: List[Int64] = [2, 1, 3, 99]
    var pk1: List[Int64] = [20, 99, 30, 99]
    var probe_rb = _build_recordbatch_i64_2(pk0, pk1)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)

    assert_equal(matches.__len__(), 2, "2 of 4 probe rows match")
    var gp0 = jbt.read_payload_i64_for(matches, 0)
    var gp1 = jbt.read_payload_i64_for(matches, 1)
    var gp2 = jbt.read_payload_i64_for(matches, 2)
    # (2,20) -> slot 1 -> [200, 201, 202].
    assert_equal(Int(gp0[0]), 200, "match (2,20) payload 0")
    assert_equal(Int(gp1[0]), 201, "match (2,20) payload 1")
    assert_equal(Int(gp2[0]), 202, "match (2,20) payload 2")
    # (3,30) -> slot 2 -> [300, 301, 302].
    assert_equal(Int(gp0[1]), 300, "match (3,30) payload 0")
    assert_equal(Int(gp1[1]), 301, "match (3,30) payload 1")
    assert_equal(Int(gp2[1]), 302, "match (3,30) payload 2")


def test_composite_2_duplicate_keys_flag() raises:
    """Build with duplicate (k0, k1) sets has_duplicate_keys = True AND
    stores BOTH rows on a per-key chain so the probe fans out M:N.

    With the per-key chain walker, a duplicate-key
    hit allocates a fresh storage slot linked onto the per-key chain
    rather than skipping the insert. So `n_slots()` (total stored
    build rows) is 2 for two rows sharing one key, and a single probe
    row matching (1,10) emits TWO MatchPairs — one per chained build
    row. `has_duplicate_keys` remains the live fast/slow probe-path
    selector (read in runtime_breaker_state / join_probe_state).
    """
    var jbt = JoinBuildTable_Untyped(
        _make_composite_2_i64_key(), _make_3_payload_i64(2), 16
    )

    # Two build rows with the same (1, 10) key, distinct payloads.
    var k0: List[Int64] = [1, 1]
    var k1: List[Int64] = [10, 10]
    var p0: List[Int64] = [100, 200]
    var p1: List[Int64] = [101, 201]
    var p2: List[Int64] = [102, 202]
    var cols = List[List[Int64]]()
    cols.append(k0^)
    cols.append(k1^)
    cols.append(p0^)
    cols.append(p1^)
    cols.append(p2^)
    var rb = _build_recordbatch_i64_n(cols)
    jbt.build_batch(BatchView(rb))

    # Both rows stored on the per-key chain (NOT deduped to 1).
    assert_equal(jbt.n_slots(), 2, "both dup rows stored on the chain")
    # Flag remains the live probe fast/slow-path selector.
    assert_true(jbt.has_duplicate_keys, "duplicate flag set")

    # One probe row on (1,10) fans out to BOTH chained build rows.
    var pk0: List[Int64] = [1]
    var pk1: List[Int64] = [10]
    var probe_rb = _build_recordbatch_i64_2(pk0, pk1)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)
    assert_equal(matches.__len__(), 2, "1 probe row fans out to 2 builds")

    # Gathered payloads cover both build rows (order-independent: the
    # chain is LIFO, so the second-inserted row is the head). Assert
    # the multiset {100, 200} for payload 0 across the two matches.
    var g0 = jbt.read_payload_i64_for(matches, 0)
    var seen_100 = Int(g0[0]) == 100 or Int(g0[1]) == 100
    var seen_200 = Int(g0[0]) == 200 or Int(g0[1]) == 200
    assert_true(seen_100, "fanout includes build row payload 100")
    assert_true(seen_200, "fanout includes build row payload 200")


# =============================================================================
# Acceptance gate (3) — STRINGCOLUMNVIEW-SUBSTRATE-V04:
# varlen STRING key build + probe round-trip. Previously STUB-raises;
# now flipped to PASS via the production StringColumnView wire-in.
# =============================================================================


def _make_string_key_layout() -> List[ColDescriptor]:
    """key_descriptors with a STRING varlen key at col_idx_in_storage=0.
    Same layout as `_make_string_key_stub` but the name documents the
    flip from STUB-raises to PASS contract.
    """
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_VAR_STRING,
            dtype_tag=DT_STRING,
            role=ROLE_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _build_recordbatch_string_and_i64(
    var s_values: List[String], i64_values: List[Int64]
) raises -> RecordBatch:
    """Build a 2-col RecordBatch: col 0 = STRING; col 1 = Int64 payload."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("p"), ArrowType.INT64, False))
    var schema = sb.build()
    var arr_s = StringArray.from_strings(s_values^)
    var l1: List[Scalar[DType.int64]] = []
    for i in range(i64_values.__len__()):
        l1.append(i64_values[i])
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_string(arr_s^))
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(l1)
        )
    )
    return rbb.build(schema^)


def test_string_key_build_probe_round_trip() raises:
    """STRING key build + probe: 3 unique keys -> probe with matching +
    missing strings; each match gets the correct payload back.

    Build:  s = ["alice", "bob", "carol"]; payload = [100, 200, 300]
    Probe:  s = ["alice", "missing", "carol", "bob"]
    Expect: 3 match pairs:
        (probe_row=0, build_slot=0)  -- alice payload 100
        (probe_row=2, build_slot=2)  -- carol payload 300
        (probe_row=3, build_slot=1)  -- bob payload 200
    """
    var jbt = JoinBuildTable_Untyped(
        _make_string_key_layout(), _make_single_i64_payload(1), 16
    )

    var build_s = List[String]()
    build_s.append(String("alice"))
    build_s.append(String("bob"))
    build_s.append(String("carol"))
    var build_payload: List[Int64] = [100, 200, 300]
    var build_rb = _build_recordbatch_string_and_i64(build_s^, build_payload)
    jbt.build_batch(BatchView(build_rb))

    assert_equal(jbt.n_slots(), 3, "3 unique string keys")
    assert_false(
        jbt.has_duplicate_keys, "no duplicates in build"
    )

    var probe_s = List[String]()
    probe_s.append(String("alice"))
    probe_s.append(String("missing"))
    probe_s.append(String("carol"))
    probe_s.append(String("bob"))
    var probe_payload: List[Int64] = [0, 0, 0, 0]  # ignored by probe path
    var probe_rb = _build_recordbatch_string_and_i64(probe_s^, probe_payload)

    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)

    assert_equal(matches.__len__(), 3, "3 match pairs (alice, carol, bob)")
    # Order is BUILD-order; probe-side ordering depends on hash bucket
    # but for unique strings + 16-cap directory, salt match is direct.
    # Validate by checking that each expected (probe_row, build_slot)
    # pair exists in the matches list.
    var found_alice = False
    var found_carol = False
    var found_bob = False
    for i in range(matches.__len__()):
        var m = matches[i]
        if m.probe_row == 0 and m.build_slot == 0:
            found_alice = True
        elif m.probe_row == 2 and m.build_slot == 2:
            found_carol = True
        elif m.probe_row == 3 and m.build_slot == 1:
            found_bob = True
    assert_true(found_alice, "alice match (probe row 0 -> build slot 0)")
    assert_true(found_carol, "carol match (probe row 2 -> build slot 2)")
    assert_true(found_bob, "bob match (probe row 3 -> build slot 1)")


# =============================================================================
# Acceptance gate (4) — empty BUILD: probe-only returns 0 matches
# =============================================================================


def test_empty_build_probe_returns_no_matches() raises:
    """Construct + probe without any build: every probe row misses;
    match_pairs length is 0."""
    var jbt = JoinBuildTable_Untyped(
        _make_single_i64_key(), _make_single_i64_payload(1), 16
    )

    assert_equal(jbt.n_slots(), 0, "empty build")

    var probe_keys: List[Int64] = [1, 2, 3]
    var probe_rb = _build_recordbatch_i64(probe_keys)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)

    assert_equal(matches.__len__(), 0, "0 matches against empty build")


# =============================================================================
# Acceptance gate (5) — large 1000-row stress
# =============================================================================


def test_large_1000_row_stress_grow_and_match() raises:
    """1000-row build + 1000-row all-match probe exercises capacity-grow
    + directory-rehash + correctness."""
    var jbt = JoinBuildTable_Untyped(
        _make_single_i64_key(), _make_single_i64_payload(1), 16
    )

    # Build 1000 unique keys -> exercises grow from 16 -> 1024.
    var build_keys = List[Int64]()
    var build_payload = List[Int64]()
    for i in range(1000):
        build_keys.append(Int64(i * 7 + 1))  # unique, spread
        build_payload.append(Int64(i * 100))
    var cols = List[List[Int64]]()
    cols.append(build_keys^)
    cols.append(build_payload^)
    var build_rb = _build_recordbatch_i64_n(cols)
    jbt.build_batch(BatchView(build_rb))

    assert_equal(jbt.n_slots(), 1000, "1000 unique slots after grow")
    assert_false(jbt.has_duplicate_keys, "unique build keys")
    assert_true(jbt.capacity() >= 1000, "capacity grew to >= 1000")

    # Probe all 1000 -> all match.
    var probe_keys = List[Int64]()
    for i in range(1000):
        probe_keys.append(Int64(i * 7 + 1))
    var probe_rb = _build_recordbatch_i64(probe_keys)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)

    assert_equal(matches.__len__(), 1000, "all 1000 probe rows match")
    # Spot-check 3 boundary positions: 0, 500, 999.
    var gathered = jbt.read_payload_i64_for(matches, 0)
    assert_equal(Int(gathered[0]), 0, "row 0 payload")
    assert_equal(Int(gathered[500]), 50000, "row 500 payload")
    assert_equal(Int(gathered[999]), 99900, "row 999 payload")



def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
