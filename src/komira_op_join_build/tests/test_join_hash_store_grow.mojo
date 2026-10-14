# =============================================================================
# JOIN-HASH-STORE — the directory rehash must not
# RE-DERIVE a build slot's hash from its stored key bytes.
# =============================================================================
#
# `JoinBuildTable_Untyped` places a build slot's chain head in its directory at
# `bucket(_hash_row(batch, row))` — the hash computed from the INPUT BATCH cell.
# On a directory grow, `_rehash_directory` used to REBUILD both the directory
# and the per-key `_chain_next` chains by RE-DERIVING each slot's hash from its
# STORED key bytes (`_hash_storage_row`). That is only sound if
#
#       _hash_row(batch, row)  ==  _hash_storage_row(slot_that_row_created)
#
# for EVERY key dtype. It is NOT. For a NEGATIVE narrow signed int key
# (DT_I16 / DT_I8) the batch side sign-extends
# (`_hash_u64(UInt64(Int(v)))`, v: Int16 = -30000 -> 0xFFFF_FFFF_FFFF_8AD0)
# while the storage side reads the two's-complement cell back UNSIGNED
# (`read_slot_u16` -> 35536). The two hashes differ, so after a rehash the whole
# chain for that key sits at a bucket no probe will ever visit again:
#
#   * `probe_batch` computes the sign-extended hash, lands on an EMPTY bucket,
#     and returns with NO MatchPair -> the join SILENTLY DROPS every matching
#     row for that key. Nothing crashes; the result set just gets smaller.
#   * a later BUILD row for the same key also misses, so it opens a SECOND
#     chain head for a key that already has one — two disjoint chains for one
#     key, and whichever one the probe finds emits only its own members.
#
# These are VALUE assertions on the JOIN OUTPUT, not row-count-only: every build
# row carries a payload that encodes (key index, occurrence), so the oracle
# checks that each probe row matched EXACTLY the two build rows that share its
# key — which catches a dropped match, a duplicated match, and a cross-key
# mismatch. A count-only assertion walks straight past a split chain.
#
# `_INIT_CAP` is chosen so the FIRST build batch forces at least two directory
# rehashes; `directory_rehashes()` is asserted > 0 so the fixture can never pass
# by simply never having grown.
#
# POSITIVE CONTROLS (pass BEFORE and AFTER the fix, so a red on the negative
# cases is the SIGN divergence and not the harness):
#   * `test_positive_i16_key_join_survives_directory_rehash` — identical fixture,
#     non-negative keys, where the two hashes agree.
#   * `test_composite_i64_key_join_survives_directory_rehash` — the wide
#     composite-key shape the corpus actually runs, proving the stored-hash
#     rehash is a no-op there.
#
# Encapsulation: public surface only — no UnsafePointer, no wildcard origin.
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

from std.testing import TestSuite, assert_equal, assert_true


# -----------------------------------------------------------------------------
# Fixture shape.
#
# `_N_KEYS` distinct keys with `_INIT_CAP` = 8 gives directory capacity 32 and
# grow_threshold 16. The directory's `n_used` counts DISTINCT keys (a duplicate
# key is linked onto its chain via `set_slot_at`, which does not occupy a new
# bucket), so batch 1 rehashes at distinct key 17 and again at 33 — both INSIDE
# batch 1, so batch 2 and the probe both run against a fully-rehashed directory.
# -----------------------------------------------------------------------------

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
    """Two I64 key cols — the compose-hash shape the corpus joins on."""
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
    """One I64 payload col, sitting after the keys in both batch + storage."""
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


def _add_narrow_key_col[
    dt: DType
](mut rbb: RecordBatchBuilder, keys: List[Int64]) raises:
    comptime if dt == DType.int16:
        rbb.add_column(Column.from_primitive[DType.int16](_i16_arr(keys)))
    else:
        rbb.add_column(Column.from_primitive[DType.int8](_i8_arr(keys)))


def _build_batch_narrow[
    dt: DType
](keys: List[Int64], payload: List[Int64], at: ArrowType) raises -> RecordBatch:
    """BUILD batch: [narrow key, I64 payload]."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), at, False))
    sb.add_field(Field(String("p"), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(2)
    _add_narrow_key_col[dt](rbb, keys)
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(payload)))
    return rbb.build(schema^)


def _probe_batch_narrow[
    dt: DType
](keys: List[Int64], at: ArrowType) raises -> RecordBatch:
    """PROBE batch: [narrow key] only — the build key descriptor reads col 0."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), at, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    _add_narrow_key_col[dt](rbb, keys)
    return rbb.build(schema^)


def _build_batch_i64x2(
    k0: List[Int64], k1: List[Int64], payload: List[Int64]
) raises -> RecordBatch:
    """BUILD batch: [I64 key, I64 key, I64 payload]."""
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


def _probe_batch_i64x2(k0: List[Int64], k1: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k0"), ArrowType.INT64, False))
    sb.add_field(Field(String("k1"), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(k0)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(k1)))
    return rbb.build(schema^)


# -----------------------------------------------------------------------------
# The VALUE oracle, shared by every case.
#
# `matches` was produced by probing with one row per key, in REVERSE key order
# (probe row r <-> key index `_N_KEYS - 1 - r`), against a build side that saw
# every key TWICE. Payload `1000*i + occ` encodes (key index, occurrence), so
# each probe row must gather exactly {1000*i+1, 1000*i+2} and nothing else.
# -----------------------------------------------------------------------------


def _assert_join_output_exact(
    imm jbt: JoinBuildTable_Untyped, imm matches: List[MatchPair]
) raises:
    assert_equal(
        len(matches),
        2 * _N_KEYS,
        "every probe row must find BOTH of its build rows",
    )
    var gathered = jbt.read_payload_i64_for(matches, 0)
    assert_equal(len(gathered), len(matches), "payload gather length")

    var seen_first = List[Bool]()
    var seen_second = List[Bool]()
    for _ in range(_N_KEYS):
        seen_first.append(False)
    for _ in range(_N_KEYS):
        seen_second.append(False)

    for m in range(len(matches)):
        var probe_row = matches[m].probe_row
        assert_true(
            probe_row >= 0 and probe_row < _N_KEYS,
            "MatchPair probe_row out of range: " + String(probe_row),
        )
        var i = _N_KEYS - 1 - probe_row
        var p = Int(gathered[m])
        if p == 1000 * i + 1:
            assert_true(
                not seen_first[i],
                "duplicate first-occurrence match for key index " + String(i),
            )
            seen_first[i] = True
        elif p == 1000 * i + 2:
            assert_true(
                not seen_second[i],
                "duplicate second-occurrence match for key index " + String(i),
            )
            seen_second[i] = True
        else:
            assert_true(
                False,
                "probe row "
                + String(probe_row)
                + " (key index "
                + String(i)
                + ") matched a build row belonging to a DIFFERENT key:"
                " payload " + String(p),
            )
    for i in range(_N_KEYS):
        assert_true(
            seen_first[i],
            "key index "
            + String(i)
            + ": first build row was DROPPED from the join output",
        )
        assert_true(
            seen_second[i],
            "key index "
            + String(i)
            + ": second build row was DROPPED from the join output",
        )


# -----------------------------------------------------------------------------
# Narrow-key case body: build the SAME `_N_KEYS` keys TWICE (a 2-long chain per
# key, across at least two directory rehashes), then probe once per key.
# -----------------------------------------------------------------------------


def _narrow_join_case[
    dt: DType
](dtype_tag: UInt8, at: ArrowType, base: Int, step: Int) raises:
    var keys = List[Int64]()
    var pay_first = List[Int64]()
    var pay_second = List[Int64]()
    for i in range(_N_KEYS):
        keys.append(Int64(base + i * step))
        pay_first.append(Int64(1000 * i + 1))
        pay_second.append(Int64(1000 * i + 2))

    var jbt = JoinBuildTable_Untyped(
        _narrow_key_desc(dtype_tag), _i64_payload_desc(1), _INIT_CAP
    )

    var b1 = _build_batch_narrow[dt](keys, pay_first, at)
    var bv1 = BatchView(b1)
    jbt.build_batch(bv1)
    # Batch 1 alone must have forced the grow this test is about.
    assert_true(
        jbt.directory_rehashes() > 0,
        "fixture is vacuous: no directory rehash occurred in batch 1",
    )

    var b2 = _build_batch_narrow[dt](keys, pay_second, at)
    var bv2 = BatchView(b2)
    jbt.build_batch(bv2)

    assert_equal(
        jbt.n_slots(), 2 * _N_KEYS, "one build slot per build row (M:N fan-out)"
    )

    # Probe once per key, in REVERSE order, so the oracle cannot pass by
    # accidentally lining up with build insertion order.
    var probe_keys = List[Int64]()
    for i in range(_N_KEYS):
        probe_keys.append(keys[_N_KEYS - 1 - i])
    var pb = _probe_batch_narrow[dt](probe_keys, at)
    var pbv = BatchView(pb)
    var matches = List[MatchPair]()
    jbt.probe_batch(pbv, matches)

    # THE PRIMARY CLAIM: the join OUTPUT. Asserted before any structural check
    # so a regression is reported as the rows it lost, not as a flag.
    _assert_join_output_exact(jbt, matches)

    # Corroborating structural check. It is a WEAKER signal than the output
    # oracle above (a key that fails to re-match keeps `n_slots` at 2*_N_KEYS
    # while producing zero matches), so it runs last.
    assert_true(
        jbt.has_duplicate_keys,
        "batch 2 repeats every key, so the duplicate-key flag must be set",
    )


# -----------------------------------------------------------------------------
# Cases.
# -----------------------------------------------------------------------------


def test_negative_i16_key_join_survives_directory_rehash() raises:
    """DT_I16, all keys negative. FAILS before JOIN-HASH-STORE: the rehash
    re-derives an UNSIGNED hash from the stored cell, so the probe's
    sign-extended hash lands on an empty bucket and the matches vanish."""
    _narrow_join_case[DType.int16](DT_I16, ArrowType.INT16, -1001, -7)


def test_negative_i8_key_join_survives_directory_rehash() raises:
    """DT_I8, all keys negative — the same divergence one width down."""
    _narrow_join_case[DType.int8](DT_I8, ArrowType.INT8, -1, -1)


def test_positive_i16_key_join_survives_directory_rehash() raises:
    """POSITIVE CONTROL. Identical fixture, non-negative keys, where the
    batch-side and storage-side hashes agree. Passes both before and after the
    fix — its job is to prove the harness (rehash count, value oracle, reverse
    probe order) is sound."""
    _narrow_join_case[DType.int16](DT_I16, ArrowType.INT16, 1001, 7)


def test_composite_i64_key_join_survives_directory_rehash() raises:
    """POSITIVE CONTROL on the WIDE composite shape the corpus actually joins
    on (2 x I64, compose-hashed). I64 has no narrow-signed divergence, so this
    passes in both arms and pins that re-inserting from the stored hash produces
    the same chains as re-deriving did."""
    var k0 = List[Int64]()
    var k1 = List[Int64]()
    var pay_first = List[Int64]()
    var pay_second = List[Int64]()
    for i in range(_N_KEYS):
        k0.append(Int64(-500000 - i * 13))
        k1.append(Int64(900000 + i * 3))
        pay_first.append(Int64(1000 * i + 1))
        pay_second.append(Int64(1000 * i + 2))

    var jbt = JoinBuildTable_Untyped(
        _composite_i64_key_desc(), _i64_payload_desc(2), _INIT_CAP
    )
    var b1 = _build_batch_i64x2(k0, k1, pay_first)
    var bv1 = BatchView(b1)
    jbt.build_batch(bv1)
    assert_true(
        jbt.directory_rehashes() > 0,
        "fixture is vacuous: no directory rehash occurred in batch 1",
    )
    var b2 = _build_batch_i64x2(k0, k1, pay_second)
    var bv2 = BatchView(b2)
    jbt.build_batch(bv2)
    assert_equal(jbt.n_slots(), 2 * _N_KEYS, "one build slot per build row")

    var p0 = List[Int64]()
    var p1 = List[Int64]()
    for i in range(_N_KEYS):
        p0.append(k0[_N_KEYS - 1 - i])
        p1.append(k1[_N_KEYS - 1 - i])
    var pb = _probe_batch_i64x2(p0, p1)
    var pbv = BatchView(pb)
    var matches = List[MatchPair]()
    jbt.probe_batch(pbv, matches)

    _assert_join_output_exact(jbt, matches)


# -----------------------------------------------------------------------------
# Structural gate: the rehash path must not RE-HASH.
#
# `storage_hash_recomputes()` counts every slot whose composite hash the rehash
# path had to re-derive from stored key bytes. For a table populated through
# `build_batch` it must be ZERO — that IS the lever. Paired with
# `directory_rehashes() >= 2` so the assertion cannot pass by never growing.
# -----------------------------------------------------------------------------


def test_join_rehash_never_rederives_stored_key_hash() raises:
    var keys = List[Int64]()
    var payload = List[Int64]()
    for i in range(_N_KEYS):
        keys.append(Int64(-1001 - i * 7))
        payload.append(Int64(1000 * i + 1))
    var jbt = JoinBuildTable_Untyped(
        _narrow_key_desc(DT_I16), _i64_payload_desc(1), _INIT_CAP
    )
    var b = _build_batch_narrow[DType.int16](keys, payload, ArrowType.INT16)
    var bv = BatchView(b)
    jbt.build_batch(bv)

    assert_true(
        jbt.directory_rehashes() >= 2,
        "expected >= 2 directory rehashes, got "
        + String(jbt.directory_rehashes()),
    )
    assert_equal(
        jbt.hash_cache_covered(),
        jbt.n_slots(),
        "every build-probed slot must carry a stored placing hash",
    )
    assert_equal(
        jbt.storage_hash_recomputes(),
        0,
        "the rehash path re-derived a hash from stored key bytes",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
