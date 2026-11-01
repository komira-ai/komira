# =============================================================================
# STRKEY-BULK JOIN TWIN — the byte-equivalence gate for the bulk
# STRING primitives on the JOIN BUILD side.
# =============================================================================
#
# WHAT CHANGED, AND WHY THIS FILE IS WHAT HOLDS IT. `join_build_untyped.mojo`
# had FIVE varlen arms that materialized a `List[UInt8]` one byte at a time,
# purely to satisfy the `_hash_bytes(List)` / `_bytes_eq(List, List)`
# signatures, and then walked the result again:
#
#   * `_encode_cell`               one List per INSERTED BUILD ROW
#   * `_hash_single_col`           one List per PROBE ROW — hotter than the
#                                  compare, because a row is hashed whether or
#                                  not it reaches a compare
#   * `_key_eq_single_col`         TWO Lists per probe that reaches a compare:
#                                  one built from `sv.byte_at(i)` (which
#                                  re-derives `batch -> columns slab -> Column
#                                  -> _data` and runs a raising bounds check ON
#                                  EVERY BYTE) and one from
#                                  `read_slot_str_bytes`
#   * `_storage_key_eq_single_col` TWO Lists per compared pair, on the rehash
#   * `_hash_storage_single_col`   one List per OCCUPIED SLOT, per grow
#
# They now go through `StringView.bytes_view()` (one resolution, a plain
# `(ptr, len)` window), `ColumnFormatStorage.slot_str_first_diff`,
# the NEW `ColumnFormatStorage.slot_str_slot_first_diff` (the storage-vs-storage
# sister: one resolution PER SLOT + an EIGHT-BYTE-AT-A-TIME compare),
# `ColumnFormatStorage.slot_str_fnv1a` and `write_slot_str_from_byteview`.
#
# ⛔⛔ EVERY ONE OF THOSE IS CLAIMED **BIT-IDENTICAL**, NOT MERELY EQUIVALENT.
# The hash keeps FNV-1a's seed, prime, byte order and `h ^= h >> 16` fold, so a
# join directory must come out slot-for-slot the same; each compare returns the
# index of the FIRST differing byte, which is exactly what the scalar loop's
# break index was, so the `keyeq_census` `bytes_touched` statistic is unmoved.
# A test that only asserted "the join still returns the right rows" would not
# hold that claim — so the matrix case below compares against an INDEPENDENT
# ORACLE WRITTEN OUT LONGHAND IN THIS FILE, never against a shipped helper that
# shares the code under test.
#
# ⚠ THE WORD ARM IS WHERE THE BUGS LIVE. A compare that reads 8 bytes at a time
# has three boundaries a byte loop does not: the last full word, the switch to
# the tail, and the narrowing back to a byte index inside a mismatching word.
# `test_slot_vs_slot_first_diff_exhaustive_matrix` therefore walks EVERY length
# 0..32 and EVERY first-difference position inside each — 528 differing pairs
# plus 33 all-equal pairs — because a fixture built from a handful of hand-
# picked strings can miss `len == 8`, or a difference at index 7, and still
# look thorough.
#
# ⚠ AND THE MATRIX ALONE IS NOT ENOUGH, BECAUSE IT CANNOT SEE THE REHASH. The
# storage-vs-storage compare and the storage-side hash are reached ONLY when
# the directory grows. `test_join_string_keys_force_directory_grow` drives 400
# distinct keys through a 16-slot table for exactly that reason: a storage-side
# hash that disagreed with the batch-side hash strands a build row in the wrong
# bucket, which surfaces as a MISSING JOIN MATCH and nothing else.
#
# Encapsulation: public Column / BatchView / ColumnFormatStorage /
# JoinBuildTable_Untyped surface only. No UnsafePointer, no wildcard origin,
# no unsafe_from_address.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field, RecordBatchBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.batch_view import BatchView

from komira_column_format.column_format_storage import (
    ColumnFormatStorage,
    ColDescriptor,
    COL_FIXED,
    COL_VAR_STRING,
    DT_I64,
    DT_STRING,
    ROLE_KEY,
    ROLE_PAYLOAD,
)
from komira_op_join_build.join_build_untyped import (
    JoinBuildTable_Untyped,
    MatchPair,
)


# -----------------------------------------------------------------------------
# Oracles — written out longhand HERE. Neither calls the code under test.
# -----------------------------------------------------------------------------


def _oracle_first_diff(a: List[UInt8], b: List[UInt8], length: Int) -> Int:
    """The scalar forward scan `slot_str_slot_first_diff` replaced: index of
    the first differing byte over `length` bytes, or -1 when all match."""
    for i in range(length):
        if a[i] != b[i]:
            return i
    return -1


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(s.byte_length()):
        out.append(s.unsafe_ptr()[unsafe_offset=i])
    return out^


# -----------------------------------------------------------------------------
# Fixtures.
# -----------------------------------------------------------------------------


def _str_storage_layout() -> List[ColDescriptor]:
    """[0] = I64 key, [1] = VAR_STRING payload — a two-col storage whose col 1
    is varlen, which is what the slot primitives address."""
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
            role=ROLE_PAYLOAD,
            col_idx_in_batch=1,
            col_idx_in_storage=1,
            validity_tracked=False,
        )
    )
    return l^


def _string_key_layout() -> List[ColDescriptor]:
    """key_descriptors: one VAR_STRING key at batch col 0 / storage col 0."""
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


def _i64_payload_at(storage_idx: Int) -> List[ColDescriptor]:
    """payload_descriptors: one I64 payload at batch col 1."""
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=10,
            kind=COL_FIXED,
            dtype_tag=DT_I64,
            role=ROLE_PAYLOAD,
            col_idx_in_batch=1,
            col_idx_in_storage=storage_idx,
            validity_tracked=False,
        )
    )
    return l^


def _str_i64_batch(
    var s_values: List[String], i64_values: List[Int64]
) raises -> RecordBatch:
    """2-col RecordBatch: col 0 = STRING, col 1 = Int64."""
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


def _ascii_payload(pattern: List[UInt8]) -> String:
    """Map each byte injectively into printable ASCII so the value survives a
    `StringArray` round trip, and the stored bytes are exactly these bytes."""
    var s = String("")
    for i in range(len(pattern)):
        s += String(chr(33 + Int(pattern[i])))
    return s


def _adversarial_keys() -> List[String]:
    """Lengths straddling the 8-byte word boundary in BOTH directions, pairs
    differing ONLY past the first word, and multi-byte UTF-8."""
    var v = List[String]()
    v.append(String("a"))
    v.append(String("abcdefg"))  # 7  — tail only
    v.append(String("abcdefgh"))  # 8  — exactly one word
    v.append(String("abcdefghi"))  # 9  — one word + 1
    v.append(String("abcdefghijklmno"))  # 15
    v.append(String("abcdefghijklmnop"))  # 16 — exactly two words
    v.append(String("abcdefghijklmnopq"))  # 17
    v.append(String("abcdefghXjklmnopq"))  # differs from ^ at index 8 ONLY
    v.append(String("Xbcdefghijklmnopq"))  # differs at index 0 ONLY
    v.append(String("abcdefghijklmnopX"))  # differs at index 16 ONLY
    v.append(String("abcdefgXijklmnopq"))  # differs at index 7 ONLY
    v.append(String("éèêëìí"))  # multi-byte UTF-8
    v.append(
        String("the/quick/brown/fox/jumps/over/the/lazy/dog/and/keeps/going")
    )
    return v^


# =============================================================================
# 1. `slot_str_slot_first_diff` == the scalar scan it replaced, EXHAUSTIVELY
#    over the word/tail boundary.
#
#    This is the ONE genuinely new primitive in the join twin: the
#    storage-vs-storage compare. The batch-vs-storage one
#    (`slot_str_first_diff`) is already pinned by
#    `test_strkey_bulk_byte_equiv.mojo` and is reused here unchanged.
# =============================================================================


def test_slot_vs_slot_first_diff_exhaustive_matrix() raises:
    """For every length 0..32 and every first-difference position inside it,
    assert `slot_str_slot_first_diff` returns the index the forward scalar scan
    would break at — and -1 exactly when the scan finds no difference.

    Both payloads are written into the SAME varlen col at DIFFERENT slots, so
    they sit at different heap offsets: the resolve this primitive hoists is
    per-slot, and a form that resolved one offset and used it for both would
    report every pair equal — which is a silent WRONG JOIN, not a crash."""
    var storage = ColumnFormatStorage.alloc(_str_storage_layout(), 64)
    var cases = 0
    var differing_cases = 0
    for length in range(0, 33):
        var pattern = List[UInt8]()
        for i in range(length):
            pattern.append(UInt8((i * 7 + 3) % 90))
        var a_bytes = _bytes(_ascii_payload(pattern.copy()))

        # (a) identical payloads in two DIFFERENT slots -> -1
        storage.write_slot_str(1, 0, a_bytes.copy())
        storage.write_slot_str(1, 1, a_bytes.copy())
        storage.set_n_slots(2)
        assert_equal(
            storage.slot_str_slot_first_diff(1, 0, 1, length),
            _oracle_first_diff(a_bytes, a_bytes, length),
            "identical, length " + String(length),
        )
        assert_equal(
            storage.slot_str_slot_first_diff(1, 0, 1, length),
            -1,
            "identical payloads must report -1, length " + String(length),
        )
        cases += 1

        # (b) exactly one differing byte, at EVERY position d
        for d in range(length):
            var mutated = pattern.copy()
            mutated[d] = UInt8((Int(pattern[d]) + 41) % 90)
            var b_bytes = _bytes(_ascii_payload(mutated.copy()))
            storage.write_slot_str(1, 1, b_bytes.copy())
            var want = _oracle_first_diff(a_bytes, b_bytes, length)
            assert_equal(
                want,
                d,
                (
                    "fixture is not what it claims: length "
                    + String(length)
                    + " should differ at "
                    + String(d)
                    + " but the oracle says "
                    + String(want)
                ),
            )
            assert_equal(
                storage.slot_str_slot_first_diff(1, 0, 1, length),
                want,
                (
                    "length "
                    + String(length)
                    + ", first diff at "
                    + String(d)
                ),
            )
            # Symmetric: the primitive must not care which slot is `a`.
            assert_equal(
                storage.slot_str_slot_first_diff(1, 1, 0, length),
                want,
                (
                    "reversed slots, length "
                    + String(length)
                    + ", first diff at "
                    + String(d)
                ),
            )
            cases += 1
            differing_cases += 1
    # 33 identical cases + sum(0..32) = 33 + 528 = 561.
    assert_equal(cases, 561, "matrix size changed; fixture is not what it says")
    assert_equal(differing_cases, 528, "differing-pair count changed")


def test_slot_vs_slot_first_diff_refuses_a_non_varlen_col() raises:
    """Col 0 of the layout is DT_I64. Asking for a string compare there must
    raise, not read the fixed buffer as a descriptor cell — the same contract
    `slot_str_first_diff` and `read_slot_str_bytes` hold."""
    var storage = ColumnFormatStorage.alloc(_str_storage_layout(), 8)
    storage.set_n_slots(2)
    var raised = False
    try:
        var _d = storage.slot_str_slot_first_diff(0, 0, 1, 4)
    except:
        raised = True
    assert_true(raised, "a non-varlen col must raise, not answer")


# =============================================================================
# 2. End-to-end through the JOIN table — the arms the matrix cannot reach.
# =============================================================================


def test_join_string_key_build_probe_round_trip() raises:
    """The probe-compare arm (`_key_eq_single_col` -> `_str_cell_eq_slot`) and
    the batch hash (`_hash_single_col` -> `_hash_string_view`) on a shape where
    every key differs at a different place."""
    var jbt = JoinBuildTable_Untyped(
        _string_key_layout(), _i64_payload_at(1), 16
    )
    var keys = _adversarial_keys()
    var build_s = List[String]()
    var build_p = List[Int64]()
    for i in range(len(keys)):
        build_s.append(keys[i])
        build_p.append(Int64(i * 100 + 7))
    var n = len(keys)
    var build_rb = _str_i64_batch(build_s^, build_p)
    jbt.build_batch(BatchView(build_rb))
    assert_equal(jbt.n_slots(), n, "every adversarial key is its OWN slot")
    assert_false(jbt.has_duplicate_keys, "the fixture has no duplicates")

    # Probe with every key plus interleaved misses that share long prefixes.
    var probe_s = List[String]()
    var probe_p = List[Int64]()
    var expect_slot = List[Int]()
    for i in range(n):
        probe_s.append(keys[i])
        probe_p.append(Int64(0))
        expect_slot.append(i)
        probe_s.append(keys[i] + String("!"))  # one byte longer: MISS
        probe_p.append(Int64(0))
        expect_slot.append(-1)
    var probe_rb = _str_i64_batch(probe_s^, probe_p)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)

    assert_equal(
        matches.__len__(), n, "exactly the n hits; every '<key>!' must miss"
    )
    var seen = List[Int]()
    for _i in range(n):
        seen.append(-1)
    for m in range(matches.__len__()):
        var pr = matches[m].probe_row
        var bs = matches[m].build_slot
        assert_equal(
            expect_slot[pr],
            bs,
            "probe row " + String(pr) + " matched the wrong build slot",
        )
        seen[bs] = pr
    for s in range(n):
        assert_true(seen[s] >= 0, "build slot " + String(s) + " never matched")


def test_join_string_keys_force_directory_grow() raises:
    """400 distinct STRING keys into a 16-slot table.

    ⭐ THIS IS THE ONLY CASE THAT REACHES THE STORAGE-SIDE ARMS. The directory
    grows several times, and each grow rehashes every occupied slot through
    `_hash_storage_single_col` -> `slot_str_fnv1a` and groups same-key slots via
    `_storage_key_eq_single_col` -> `slot_str_slot_first_diff`. A storage-side
    hash that disagreed with the batch-side hash strands a build row in the
    wrong bucket, and the ONLY symptom is a probe that no longer finds it."""
    var jbt = JoinBuildTable_Untyped(
        _string_key_layout(), _i64_payload_at(1), 16
    )
    var keys = List[String]()
    for i in range(400):
        # Vary length across BOTH word boundaries as well as content, so the
        # rehash exercises the word arm and the tail arm alike.
        var pad = String("")
        for _p in range(i % 19):
            pad += String("z")
        keys.append(String("join-key-") + String(i) + pad)
    var build_s = List[String]()
    var build_p = List[Int64]()
    for i in range(400):
        build_s.append(keys[i])
        build_p.append(Int64(i * 3 + 1))
    var build_rb = _str_i64_batch(build_s^, build_p)
    jbt.build_batch(BatchView(build_rb))
    assert_equal(jbt.n_slots(), 400, "400 distinct string keys")
    assert_false(jbt.has_duplicate_keys, "400 distinct keys, no duplicates")
    assert_true(
        jbt.directory_rehashes() > 0,
        (
            "VACUOUS: the directory never grew, so the storage-side hash and"
            " the storage-vs-storage compare were never executed"
        ),
    )

    # Every key must still be findable, and must carry ITS OWN payload.
    var probe_s = List[String]()
    var probe_p = List[Int64]()
    for i in range(400):
        probe_s.append(keys[399 - i])  # reversed, so bucket order is not row order
        probe_p.append(Int64(0))
    var probe_rb = _str_i64_batch(probe_s^, probe_p)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)
    assert_equal(matches.__len__(), 400, "all 400 keys must still be found")
    var got = jbt.read_payload_i64_for(matches, 0)
    for m in range(matches.__len__()):
        var want_build_row = 399 - matches[m].probe_row
        assert_equal(
            Int(got[m]),
            want_build_row * 3 + 1,
            (
                "probe row "
                + String(matches[m].probe_row)
                + " reached a slot carrying the wrong payload"
            ),
        )


def test_join_string_keys_sharing_a_long_prefix_do_not_collapse() raises:
    """Keys identical for the first 24 bytes and differing only in the tail.

    The word arm compares 8 bytes at a time and must narrow back to the exact
    differing byte; a form that returned the WORD index instead of the byte
    index still answers "not equal" here, so this case is about the join being
    right, while the matrix above is what pins the index itself."""
    var jbt = JoinBuildTable_Untyped(
        _string_key_layout(), _i64_payload_at(1), 8
    )
    var prefix = String("aaaaaaaabbbbbbbbcccccccc")  # exactly 24 bytes
    var build_s = List[String]()
    var build_p = List[Int64]()
    for i in range(64):
        build_s.append(prefix + String("-") + String(i))
        build_p.append(Int64(1000 + i))
    var build_rb = _str_i64_batch(build_s^, build_p)
    jbt.build_batch(BatchView(build_rb))
    assert_equal(jbt.n_slots(), 64, "64 long-shared-prefix keys are distinct")

    var probe_s = List[String]()
    var probe_p = List[Int64]()
    for i in range(64):
        probe_s.append(prefix + String("-") + String(i))
        probe_p.append(Int64(0))
    var probe_rb = _str_i64_batch(probe_s^, probe_p)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)
    assert_equal(matches.__len__(), 64, "each key matches exactly once")
    var got = jbt.read_payload_i64_for(matches, 0)
    for m in range(matches.__len__()):
        assert_equal(
            Int(got[m]),
            1000 + matches[m].probe_row,
            "long-prefix key reached the wrong slot",
        )


def test_join_string_key_duplicates_chain_not_collapse() raises:
    """The same STRING key inserted twice must set `has_duplicate_keys` and
    fan out on probe — the compare saying "equal" is load-bearing in BOTH
    directions, and a compare stuck at "not equal" would silently produce a
    1-row result where 3 are correct."""
    var jbt = JoinBuildTable_Untyped(
        _string_key_layout(), _i64_payload_at(1), 16
    )
    var build_s = List[String]()
    var build_p = List[Int64]()
    for i in range(3):
        build_s.append(String("abcdefghijklmnop"))  # exactly two words
        build_p.append(Int64(10 + i))
    build_s.append(String("abcdefghijklmnoq"))  # differs at index 15 only
    build_p.append(Int64(99))
    var build_rb = _str_i64_batch(build_s^, build_p)
    jbt.build_batch(BatchView(build_rb))
    assert_true(jbt.has_duplicate_keys, "the repeated key must be detected")

    var probe_s = List[String]()
    probe_s.append(String("abcdefghijklmnop"))
    var probe_p: List[Int64] = [0]
    var probe_rb = _str_i64_batch(probe_s^, probe_p)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)
    assert_equal(matches.__len__(), 3, "one probe row fans out to 3 build rows")
    var got = jbt.read_payload_i64_for(matches, 0)
    for m in range(matches.__len__()):
        var p = Int(got[m])
        assert_true(
            p >= 10 and p <= 12,
            (
                "the fan-out reached the near-miss key (payload "
                + String(p)
                + "); a one-byte tail difference must not match"
            ),
        )


def test_join_empty_and_single_byte_string_keys() raises:
    """Length 0 and length 1 keys — the two lengths the word arm can never be
    entered for, and the two a `>= 8` fast path is most likely to mishandle."""
    var jbt = JoinBuildTable_Untyped(
        _string_key_layout(), _i64_payload_at(1), 16
    )
    var build_s = List[String]()
    build_s.append(String(""))
    build_s.append(String("a"))
    build_s.append(String("b"))
    var build_p: List[Int64] = [1, 2, 3]
    var build_rb = _str_i64_batch(build_s^, build_p)
    jbt.build_batch(BatchView(build_rb))
    assert_equal(jbt.n_slots(), 3, "empty / 'a' / 'b' are three distinct keys")

    var probe_s = List[String]()
    probe_s.append(String("b"))
    probe_s.append(String(""))
    probe_s.append(String("c"))
    probe_s.append(String("a"))
    var probe_p: List[Int64] = [0, 0, 0, 0]
    var probe_rb = _str_i64_batch(probe_s^, probe_p)
    var matches = List[MatchPair]()
    jbt.probe_batch(BatchView(probe_rb), matches)
    assert_equal(matches.__len__(), 3, "'c' must miss; the other three hit")
    var want = List[Int]()
    want.append(3)  # probe row 0 -> "b" -> payload 3
    want.append(1)  # probe row 1 -> ""  -> payload 1
    want.append(-1)  # probe row 2 -> "c" -> no match
    want.append(2)  # probe row 3 -> "a" -> payload 2
    var got = jbt.read_payload_i64_for(matches, 0)
    for m in range(matches.__len__()):
        assert_equal(
            Int(got[m]),
            want[matches[m].probe_row],
            "probe row " + String(matches[m].probe_row) + " wrong payload",
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
