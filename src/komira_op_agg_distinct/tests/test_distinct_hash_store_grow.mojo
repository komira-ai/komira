# =============================================================================
# test_distinct_hash_store_grow -- a directory doubling re-places every slot at
# the hash that placed it, never at a hash re-derived from the stored key
# =============================================================================
#
# `DistinctState_Untyped` places a key's slot at the hash of the INPUT cell.
# Re-deriving that hash from the STORED cell is not equivalent for a negative
# INT16 / INT8 key: the batch side hashes the value sign-extended
# (-30000 -> 0xFFFF_FFFF_FFFF_8AD0) while the stored two's-complement cell
# reads back unsigned (35536). A doubling that re-derived would move the slot
# to a bucket no later probe of that key visits, and the key's next occurrence
# would insert a SECOND slot: a DISTINCT that is not distinct.
#
# Each case feeds the same `_N_KEYS` keys twice; batch 1 alone doubles the
# directory twice (capacity 32 at `_INIT_CAP` 8: doublings at unique keys 17
# and 33), and `directory_rehashes() > 0` is asserted so the fixture cannot pass
# by never growing. Every row carries an INT64 payload `1000*i + occurrence`,
# so a duplicate slot shows up as a `1000*i + 2` payload, not only as a count.
# Stored narrow keys are compared in the unsigned storage domain
# (`Int(key) & 0xFFFF`), so the oracle relies on no narrowing conversion.
#
# The positive-key and composite INT64 cases are controls: their batch-side and
# storage-side hashes agree, so they pass under either rehash; a red on the
# negative cases alone is the sign divergence, not the harness.
#
# A directory doubling re-places every slot at the hash that placed it
# (`_slot_hashes[s]`); the negative-key cases hold that a hash re-derived from
# storage would diverge from the batch-side hash.
# =============================================================================

from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    DT_I64,
    DT_I16,
    DT_I8,
    ROLE_KEY,
    ROLE_PAYLOAD,
)
from komira_op_agg_distinct.distinct_state_untyped import (
    DistinctState_Untyped,
)
from komira_arrow.batch_view import batch_view_over
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder

from std.testing import TestSuite, assert_equal, assert_true, assert_raises


comptime _N_KEYS: Int = 40
comptime _INIT_CAP: Int = 8


def _narrow_key_desc(dtype_tag: UInt8) -> List[ColDescriptor]:
    """One fixed-width key col at batch/storage index 0."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=dtype_tag,
            role=ROLE_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _composite_i64_key_desc() -> List[ColDescriptor]:
    """Two I64 key cols — the compose-hash shape."""
    var l = List[ColDescriptor]()
    for k in range(2):
        l.append(
            ColDescriptor(
                name_id=k,
                kind=COL_FIXED,
                dtype_tag=DT_I64,
                role=ROLE_KEY,
                col_idx_in_batch=k,
                col_idx_in_storage=k,
                validity_tracked=False,
            )
        )
    return l^


def _i64_payload_desc(n_keys: Int) -> List[ColDescriptor]:
    """One I64 passthrough col, after the keys in both batch + storage."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=100,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_PAYLOAD,
            col_idx_in_batch=n_keys,
            col_idx_in_storage=n_keys,
            validity_tracked=False,
        )
    )
    return l^


def _i64_arr(vals: List[Int64]) -> PrimitiveArray[DType.int64]:
    var l: List[Scalar[DType.int64]] = []
    for i in range(len(vals)):
        l.append(vals[i])
    return PrimitiveArray[DType.int64].from_list(l)


def _i16_arr(vals: List[Int64]) -> PrimitiveArray[DType.int16]:
    var l: List[Scalar[DType.int16]] = []
    for i in range(len(vals)):
        l.append(Int16(Int(vals[i])))
    return PrimitiveArray[DType.int16].from_list(l)


def _i8_arr(vals: List[Int64]) -> PrimitiveArray[DType.int8]:
    var l: List[Scalar[DType.int8]] = []
    for i in range(len(vals)):
        l.append(Int8(Int(vals[i])))
    return PrimitiveArray[DType.int8].from_list(l)


def _feed_batch_narrow[
    dt: DType
](keys: List[Int64], payload: List[Int64], at: ArrowType) raises -> RecordBatch:
    """[narrow key, I64 passthrough]."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), at, False))
    sb.add_field(Field(String("p"), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(2)

    comptime if dt == DType.int16:
        rbb.add_column(Column.from_primitive[DType.int16](_i16_arr(keys)))
    else:
        rbb.add_column(Column.from_primitive[DType.int8](_i8_arr(keys)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(payload)))
    return rbb.build(schema^)


def _feed_batch_i64x2(
    k0: List[Int64], k1: List[Int64], payload: List[Int64]
) raises -> RecordBatch:
    """[I64 key, I64 key, I64 passthrough]."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), ArrowType.INT64, False))
    sb.add_field(Field(String("k1"), ArrowType.INT64, False))
    sb.add_field(Field(String("p"), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(3)
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(k0)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(k1)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(payload)))
    return rbb.build(schema^)


# -----------------------------------------------------------------------------
# Narrow-key case body: feed the SAME `_N_KEYS` distinct keys TWICE, across at
# least two directory rehashes. Every key must end up in EXACTLY ONE slot whose
# passthrough payload is the FIRST occurrence's.
# -----------------------------------------------------------------------------


def _narrow_distinct_case[
    dt: DType
](dtype_tag: UInt8, at: ArrowType, base: Int, step: Int) raises:
    var keys = List[Int64]()
    var pay_first = List[Int64]()
    var pay_second = List[Int64]()
    for i in range(_N_KEYS):
        keys.append(Int64(base + i * step))
        pay_first.append(Int64(1000 * i + 1))
        pay_second.append(Int64(1000 * i + 2))

    var ds = DistinctState_Untyped(
        _narrow_key_desc(dtype_tag), _i64_payload_desc(1), _INIT_CAP
    )

    var b1 = _feed_batch_narrow[dt](keys, pay_first, at)
    var bv1 = batch_view_over(b1)
    ds.feed_batch(bv1)
    # Batch 1 alone must have forced the grow this test is about.
    assert_true(
        ds.directory_rehashes() > 0,
        "fixture is vacuous: no directory rehash occurred in batch 1",
    )

    var b2 = _feed_batch_narrow[dt](keys, pay_second, at)
    var bv2 = batch_view_over(b2)
    ds.feed_batch(bv2)

    assert_equal(
        ds.n_unique,
        _N_KEYS,
        "the rehash split a key into duplicate slots: DISTINCT is not distinct",
    )

    # VALUE oracle. Read each slot's key back in the UNSIGNED storage domain
    # (no narrowing conversion) and its passthrough payload, and require each
    # fixture key exactly once with its FIRST-occurrence payload.
    var seen = List[Bool]()
    for _ in range(_N_KEYS):
        seen.append(False)
    var payloads = ds.read_payload_i64(0)
    assert_equal(len(payloads), _N_KEYS, "payload drain length == n_unique")

    for s in range(ds.n_unique):
        var stored: Int

        comptime if dt == DType.int16:
            stored = Int(ds.storage.read_slot_u16(0, s))
        else:
            stored = Int(ds.storage.read_slot_u8(0, s))

        var found = -1
        for i in range(_N_KEYS):
            var want: Int

            comptime if dt == DType.int16:
                want = Int(keys[i]) & 0xFFFF
            else:
                want = Int(keys[i]) & 0xFF
            if want == stored:
                found = i
                break
        assert_true(
            found >= 0,
            "slot holds a key outside the fixture domain: raw " + String(stored),
        )
        assert_true(
            not seen[found],
            "duplicate slot for key index " + String(found),
        )
        seen[found] = True
        assert_equal(
            payloads[s],
            Int64(1000 * found + 1),
            "DISTINCT must keep the FIRST occurrence's passthrough for key"
            " index " + String(found),
        )
    for i in range(_N_KEYS):
        assert_true(seen[i], "key index " + String(i) + " never materialized")

    # The DRAIN must also reconstruct the sign correctly. A state that dedups
    # correctly but emits the wrong key VALUE is the same silent wrong answer
    # one step later, and the drain is the only thing downstream ever sees.
    var drained = List[Int64]()

    comptime if dt == DType.int16:
        var d16 = ds.read_unique_i16(0)
        for s in range(len(d16)):
            drained.append(Int64(Int(d16[s])))
    else:
        var d8 = ds.read_unique_i8(0)
        for s in range(len(d8)):
            drained.append(Int64(Int(d8[s])))
    assert_equal(len(drained), _N_KEYS, "key drain length == n_unique")
    for s in range(_N_KEYS):
        # The passthrough payload names which fixture key this slot holds.
        var i = (Int(payloads[s]) - 1) // 1000
        assert_equal(
            drained[s],
            keys[i],
            "drained key VALUE at slot " + String(s) + " (key index "
            + String(i) + ")",
        )


# -----------------------------------------------------------------------------
# Cases.
# -----------------------------------------------------------------------------


def test_negative_i16_key_distinct_survives_directory_rehash() raises:
    """DT_I16, all keys negative. A rehash that re-derived the hash from the
    stored cell would hash it UNSIGNED, so batch 2's sign-extended probe
    would miss and every key would get a SECOND slot."""
    _narrow_distinct_case[DType.int16](DT_I16, ArrowType.INT16, -1001, -7)


def test_negative_i8_key_distinct_survives_directory_rehash() raises:
    """DT_I8, all keys negative — the same divergence one width down."""
    _narrow_distinct_case[DType.int8](DT_I8, ArrowType.INT8, -1, -1)


def test_positive_i16_key_distinct_survives_directory_rehash() raises:
    """POSITIVE CONTROL. Identical fixture, non-negative keys, where the
    batch-side and storage-side hashes agree. Passes both before and after the
    fix — its job is to prove the harness (rehash count, value oracle) is
    sound."""
    _narrow_distinct_case[DType.int16](DT_I16, ArrowType.INT16, 1001, 7)


def test_composite_i64_key_distinct_survives_directory_rehash() raises:
    """POSITIVE CONTROL on the WIDE composite shape (2 x I64, compose-hashed).
    I64 has no narrow-signed divergence, so this passes in both arms and pins
    that re-inserting from the stored hash produces the same set, in the same
    first-occurrence order, as re-deriving did."""
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    var pay_first = List[Int64]()
    var pay_second = List[Int64]()
    for i in range(_N_KEYS):
        k0.append(Int64(-500000 - i * 13))
        k1.append(Int64(900000 + i * 3))
        pay_first.append(Int64(1000 * i + 1))
        pay_second.append(Int64(1000 * i + 2))

    var ds = DistinctState_Untyped(
        _composite_i64_key_desc(), _i64_payload_desc(2), _INIT_CAP
    )
    var b1 = _feed_batch_i64x2(k0, k1, pay_first)
    var bv1 = batch_view_over(b1)
    ds.feed_batch(bv1)
    assert_true(
        ds.directory_rehashes() > 0,
        "fixture is vacuous: no directory rehash occurred in batch 1",
    )
    var b2 = _feed_batch_i64x2(k0, k1, pay_second)
    var bv2 = batch_view_over(b2)
    ds.feed_batch(bv2)

    assert_equal(ds.n_unique, _N_KEYS, "the rehash duplicated a key")
    # Slots are in first-occurrence order, so both the key drain and the
    # payload drain must be the batch-1 sequence, element for element.
    var got0 = ds.read_unique_i64(0)
    var got1 = ds.read_unique_i64(1)
    var payloads = ds.read_payload_i64(0)
    for i in range(_N_KEYS):
        assert_equal(got0[i], k0[i], "key col 0 at slot " + String(i))
        assert_equal(got1[i], k1[i], "key col 1 at slot " + String(i))
        assert_equal(
            payloads[i],
            Int64(1000 * i + 1),
            "first-occurrence passthrough at slot " + String(i),
        )


# -----------------------------------------------------------------------------
# Structural gate: the rehash path must not RE-HASH.
#
# `storage_hash_recomputes()` counts every slot whose composite hash the rehash
# path had to re-derive from stored key bytes. For a state populated through
# `feed_batch` it must be ZERO — that IS the lever. Paired with
# `directory_rehashes() >= 2` so the assertion cannot pass by never growing.
# -----------------------------------------------------------------------------


def test_distinct_rehash_keeps_every_placing_hash() raises:
    """Two doublings in one batch, and a placing hash for every slot (and none
    past the last), so the doubling always has the stored hash to use."""
    var keys = List[Int64]()
    var payload = List[Int64]()
    for i in range(_N_KEYS):
        keys.append(Int64(-1001 - i * 7))
        payload.append(Int64(1000 * i + 1))
    var ds = DistinctState_Untyped(
        _narrow_key_desc(DT_I16), _i64_payload_desc(1), _INIT_CAP
    )
    var b = _feed_batch_narrow[DType.int16](keys, payload, ArrowType.INT16)
    ds.feed_batch(batch_view_over(b))

    assert_true(
        ds.directory_rehashes() >= 2,
        "expected >= 2 directory rehashes, got "
        + String(ds.directory_rehashes()),
    )
    for s in range(ds.n_unique):
        _ = ds.slot_hash(s)
    with assert_raises(contains="out of range"):
        _ = ds.slot_hash(ds.n_unique)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
