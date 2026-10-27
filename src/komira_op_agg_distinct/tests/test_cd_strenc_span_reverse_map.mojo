# =============================================================================
# CDPSPAN / CDPHT — the STRING-key encode's reverse map is a packed BYTE ARENA
# addressed by (start, len), and its dict-id table is an OPEN-ADDRESSED probe
# chain that resolves a hash collision by CONTINUING to probe
# =============================================================================
#
# WHAT CHANGED AND WHY THIS FILE EXISTS. `count(DISTINCT user_id) GROUP BY
# search_phrase` encodes millions of rows into millions of distinct string
# keys. The reverse map used to be a
# `List[String]` — one OWNING `String` per distinct value, i.e. one `malloc`
# in the encode, one `String` copy-construction at emit and two `free`s at
# teardown per value, for a value whose (offset, length) the encode loop already had in
# hand. Mojo 1.0.0 `String` has NO small-string optimization
# (`size_of[String]() == 24`), so each one really is a heap round trip.
#
# It is now ONE geometrically grown byte arena plus `rev_starts[d]` /
# `rev_lens[d]`. And the `Dict[Int64, Int64]` (hash -> id) + `Dict[String,
# Int64]` (collision fallback) PAIR is now a single open-addressed table with
# linear probing and verify-on-hit against the arena.
#
# THE COLLISION CASE IS THE WHOLE CORRECTNESS RISK, AND NATURAL DATA CANNOT
# REACH IT. Two distinct values sharing a 64-bit FNV-1a hash is a ~2^-32
# birthday event; no fixture of a plausible size produces one, and forging a
# pair requires ~2^32 work. So the collision arm of the incumbent was, in
# practice, never executed by any test — and the replacement's collision arm is
# a DIFFERENT mechanism (keep probing, rather than consult a second
# String-keyed Dict). A silently-wrong merge of two distinct group keys into
# one is the failure it would produce, which is exactly the class the corpus
# value gate exists to catch and which unit tests here should catch first.
#
# THE WAY IN: `_assign_dict_ids_from_hashes` takes the per-row hashes as an
# ARGUMENT (that is what makes it shareable between the parallel Phase A and
# the serial fallback's own pre-pass). So a test can HAND it a hash vector.
# `test_all_rows_share_one_hash_*` passes an all-zero hash vector: every
# distinct value collides, on one slot, and the only thing that can still tell
# them apart is the byte compare. It needs no forged FNV pair and no 2^32
# search.
#
# THE DATA/OFFSET POINTERS COME FROM A REAL BUILT COLUMN, via the same
# `view_ro()` read the driver itself uses, so the test cannot pass because it
# fed the encoder a layout the driver never produces.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_counters.keyeq_census import KEYEQ_AGGCD_STRENC

from komira_op_agg_distinct.agg_count_distinct_strenc import (
    _assign_dict_ids_from_hashes,
)
# The table sizing both Phase B bodies share moved with the sharded one
# (2026-09-24, L2/L3).
from komira_op_agg_distinct.agg_cd_strenc_parb import (
    _strenc_ht_initial_cap,
    _strenc_ht_limit,
)


# =============================================================================
# Fixture plumbing
# =============================================================================


def _string_batch(imm vals: List[String]) raises -> RecordBatch:
    """A one-column STRING batch holding `vals` verbatim."""
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_string(StringArray.from_strings(vals)))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    return rbb.build(sb.build())


struct _Encoded(Movable):
    """What `_assign_dict_ids_from_hashes` filled in."""

    var encoded: List[Int]
    var rev_bytes: List[UInt8]
    var rev_starts: List[Int]
    var rev_lens: List[Int]

    def __init__(
        out self,
        var encoded: List[Int],
        var rev_bytes: List[UInt8],
        var rev_starts: List[Int],
        var rev_lens: List[Int],
    ):
        self.encoded = encoded^
        self.rev_bytes = rev_bytes^
        self.rev_starts = rev_starts^
        self.rev_lens = rev_lens^

    def value_at(self, d: Int) -> String:
        """Decode dict id `d` out of the ARENA — the emit's own read."""
        var s = self.rev_starts[d]
        return String(
            StringSlice(unsafe_from_utf8=Span(self.rev_bytes)[s : s + self.rev_lens[d]])
        )


def _encode(imm batch: RecordBatch, var hashes: List[Int64]) raises -> _Encoded:
    """Drive the shared Phase B over column 0 with a CALLER-SUPPLIED hash
    vector. Reads the data/offsets buffers exactly as the driver does."""
    var n = batch.num_rows()
    ref col_ptr = batch.column_at(0)
    var data_view = col_ptr._data.view_ro()
    var data_ptr = data_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()
    var offs_view = col_ptr._offsets.value().view_ro()
    var offs_ptr = offs_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()

    var encoded = List[Int]()
    var rev_bytes = List[UInt8]()
    var rev_starts = List[Int]()
    var rev_lens = List[Int]()
    _assign_dict_ids_from_hashes[DType.int32](
        hashes,
        data_ptr,
        offs_ptr,
        n,
        KEYEQ_AGGCD_STRENC,
        encoded,
        rev_bytes,
        rev_starts,
        rev_lens,
    )
    _ = batch
    return _Encoded(encoded^, rev_bytes^, rev_starts^, rev_lens^)


def _fnv_like(imm s: String) -> Int64:
    """A hash that is NOT the production one — this file supplies hashes on
    purpose, and using the real FNV here would make the collision tests
    unreachable again."""
    comptime BASIS = Int64(-3750763034362895579)
    comptime PRIME = Int64(1099511628211)
    var h = BASIS
    for b in s.as_bytes():
        h = (h ^ Int64(b)) * PRIME
    return h ^ (Int64(s.byte_length()) * PRIME)


def _assert_round_trips(
    imm e: _Encoded, imm vals: List[String], imm msg: String
) raises:
    """Every row's dict id must decode, out of the arena, to that row's own
    value — the property a wrongly-merged collision breaks."""
    assert_equal(len(e.encoded), len(vals), msg + ": one id per row")
    for r in range(len(vals)):
        var d = e.encoded[r]
        assert_true(
            d >= 0 and d < len(e.rev_starts),
            msg + ": row " + String(r) + " id out of range",
        )
        assert_equal(
            e.value_at(d),
            vals[r],
            msg + ": row " + String(r) + " decoded to the wrong value",
        )


def _distinct_count(imm vals: List[String]) raises -> Int:
    var seen = Dict[String, Bool]()
    for v in vals:
        seen[v.copy()] = True
    return len(seen)


# =============================================================================
# §1 — the reverse map is a PACKED ARENA
# =============================================================================


def test_reverse_map_is_a_packed_byte_arena() raises:
    """`rev_bytes` holds EXACTLY the concatenated distinct values: no per-value
    header, no NUL terminator, no padding.

    Fails if: re-introducing a per-value `String` (the signature no longer
    admits one, so that change does not compile — which is the point); or by
    a NUL-terminated arena copy, which this file's byte arithmetic catches.
    """
    var vals: List[String] = [
        String("alpha"), String("beta"), String("alpha"), String(""),
        String("gamma-longer-value"), String("beta"), String(""),
    ]
    var hashes = List[Int64]()
    for v in vals:
        hashes.append(_fnv_like(v))
    var e = _encode(_string_batch(vals), hashes^)

    var sum_lens = 0
    for d in range(len(e.rev_lens)):
        sum_lens += e.rev_lens[d]
    assert_equal(
        len(e.rev_bytes),
        sum_lens,
        "the arena must be exactly the sum of the distinct value lengths",
    )
    assert_equal(
        len(e.rev_starts), len(e.rev_lens), "starts and lens are parallel"
    )
    assert_equal(
        len(e.rev_starts),
        _distinct_count(vals),
        "one reverse entry per DISTINCT value",
    )
    _assert_round_trips(e, vals, "packed arena")


def test_ids_are_minted_in_first_occurrence_order() raises:
    """The dict-id numbering contract the encoded column depends on.

    Fails if: minting ids in any other order (e.g. slot order).
    """
    var vals: List[String] = [
        String("zeta"), String("alpha"), String("zeta"), String("mu"),
        String("alpha"), String("mu"), String("zeta"),
    ]
    var hashes = List[Int64]()
    for v in vals:
        hashes.append(_fnv_like(v))
    var e = _encode(_string_batch(vals), hashes^)

    assert_equal(e.value_at(0), String("zeta"), "id 0 is the first value seen")
    assert_equal(e.value_at(1), String("alpha"), "id 1 is the second")
    assert_equal(e.value_at(2), String("mu"), "id 2 is the third")
    assert_equal(e.encoded[0], 0, "row 0")
    assert_equal(e.encoded[1], 1, "row 1")
    assert_equal(e.encoded[2], 0, "row 2 repeats the first value")
    assert_equal(e.encoded[6], 0, "row 6 repeats the first value")


def test_zero_length_value_round_trips() raises:
    """An empty key is a real value with its own id, not an absent one."""
    var vals: List[String] = [
        String(""), String("x"), String(""), String("y"), String(""),
    ]
    var hashes = List[Int64]()
    for v in vals:
        hashes.append(_fnv_like(v))
    var e = _encode(_string_batch(vals), hashes^)
    assert_equal(len(e.rev_starts), 3, "'', 'x', 'y'")
    assert_equal(e.rev_lens[0], 0, "the empty value's span is zero-length")
    assert_equal(e.encoded[0], e.encoded[2], "both empties share one id")
    assert_equal(e.encoded[0], e.encoded[4], "and so does the third")
    _assert_round_trips(e, vals, "empty value")


# =============================================================================
# §2 — THE COLLISION ARM. Every value on ONE hash.
# =============================================================================


def test_all_rows_share_one_hash_still_separates_every_value() raises:
    """REGRESSION TEST FOR THE OPEN-ADDRESSING REWRITE.

    Every row is handed hash 0, so every distinct value collides on the same
    home slot and the ONLY thing that can tell two values apart is the
    verify-on-hit byte compare followed by CONTINUED probing.

    Fails if: replacing the probe-continue on a verify FAILURE with a `break`
    (the value is then merged into whichever value happens to hold the slot —
    two different group keys become one group, silently); by breaking on the
    first hash match without comparing bytes; or by minting a fresh id for a
    value already present (the distinct count then inflates).

    The incumbent `Dict[Int64, Int64]` + `Dict[String, Int64]` pair had a
    collision arm too, and nothing in this repo ever executed it: a natural
    64-bit FNV-1a collision is a ~2^-32 event.
    """
    var vals = List[String]()
    for i in range(64):
        vals.append("value-" + String(i))
    for i in range(64):
        vals.append("value-" + String(63 - i))
    var hashes = List[Int64](length=len(vals), fill=Int64(0))
    var e = _encode(_string_batch(vals), hashes^)

    assert_equal(
        len(e.rev_starts), 64, "64 distinct values, all on one hash"
    )
    _assert_round_trips(e, vals, "all-collide")
    for i in range(64):
        assert_equal(
            e.encoded[i],
            e.encoded[127 - i],
            "the same value must get the same id on its second pass",
        )


def test_two_values_one_hash_do_not_merge() raises:
    """The minimal shape of the same defect: exactly two values, one hash.

    Fails if: the same changes as above. Kept separate because a 64-value
    chain can mask a bug that only shows at the head of the chain.
    """
    var vals: List[String] = [
        String("AA"), String("BB"), String("AA"), String("BB"),
    ]
    var hashes = List[Int64](length=4, fill=Int64(7))
    var e = _encode(_string_batch(vals), hashes^)
    assert_equal(len(e.rev_starts), 2, "two distinct values")
    assert_false(
        e.encoded[0] == e.encoded[1],
        "'AA' and 'BB' share a hash but are NOT the same group key",
    )
    _assert_round_trips(e, vals, "two on one hash")


def test_equal_length_prefix_values_on_one_hash() raises:
    """Same length, shared prefix, one hash — the case a byte compare that
    stops early, or one that compares only the length, gets wrong."""
    var vals: List[String] = [
        String("abcde"), String("abcdf"), String("abcdf"), String("abcde"),
        String("abcdg"),
    ]
    var hashes = List[Int64](length=5, fill=Int64(-1))
    var e = _encode(_string_batch(vals), hashes^)
    assert_equal(len(e.rev_starts), 3, "three distinct 5-byte values")
    assert_equal(e.encoded[0], e.encoded[3], "abcde")
    assert_equal(e.encoded[1], e.encoded[2], "abcdf")
    _assert_round_trips(e, vals, "shared prefix on one hash")


# =============================================================================
# §3 — the table REHASHES, and a rehash preserves every chain
# =============================================================================


def test_table_rehash_preserves_every_mapping() raises:
    """More distinct values than the initial table admits, so it grows.

    THE FIXTURE SIZE IS NOT FREE TO CHOOSE, and the first draft of this test
    got it wrong. The initial capacity is `next_pow2(num_rows)`, so
    `distinct <= num_rows <= cap` always — and the 0.75 load ceiling is only
    crossed when `distinct > 0.75 * next_pow2(num_rows)`, i.e. when the row
    count sits just ABOVE a power of two AND nearly every row is distinct.
    1,600 distinct values in 1,800 rows: cap = 2048, ceiling = 1536, and
    1600 > 1536. Padding the fixture with repeats to "make it bigger" pushes
    `num_rows` to the next power of two and silently removes the rehash — the
    assertion below is what makes that a RED rather than a vacuous pass.

    The last 200 rows repeat values already minted, so they probe the table
    AFTER it has been rebuilt: an id that moved in the rehash is caught here.

    Fails if: dropping live slots in the rehash loop; rebuilding with the OLD
    mask; skipping the rehash entirely (the table then fills and the probe loop
    never terminates, which this test turns into a hang rather than a red —
    stated here so a future reader knows which failure mode is which).
    """
    comptime N_DISTINCT = 1_600
    comptime N_REPEAT = 200
    comptime N_ROWS = N_DISTINCT + N_REPEAT
    assert_true(
        N_DISTINCT > _strenc_ht_limit(_strenc_ht_initial_cap(N_ROWS)),
        "the fixture must actually cross the rehash threshold: "
        + String(N_DISTINCT)
        + " distinct vs a ceiling of "
        + String(_strenc_ht_limit(_strenc_ht_initial_cap(N_ROWS))),
    )
    var vals = List[String]()
    for i in range(N_DISTINCT):
        vals.append("k" + String(i))
    for i in range(N_REPEAT):
        vals.append("k" + String(i))
    var hashes = List[Int64]()
    for v in vals:
        hashes.append(_fnv_like(v))
    var e = _encode(_string_batch(vals), hashes^)

    assert_equal(
        len(e.rev_starts), N_DISTINCT, "exactly the distinct values, after growth"
    )
    _assert_round_trips(e, vals, "after rehash")
    for i in range(N_REPEAT):
        assert_equal(
            e.encoded[i],
            e.encoded[N_DISTINCT + i],
            "a repeat seen AFTER the rehash must resolve to the id minted"
            " before it",
        )


def test_rehash_under_a_shared_hash_chain() raises:
    """Growth AND collision at once: every value on hash 0, sized to rehash.

    2,000 distinct values in 2,000 rows: cap = 2048, ceiling = 1536, so the
    table doubles while carrying ONE probe chain 1,536 entries long, and the
    rehash has to rebuild that chain. Fails on the union of the §2 and §3
    changes.
    """
    comptime N = 2_000
    assert_true(
        N > _strenc_ht_limit(_strenc_ht_initial_cap(N)),
        "the fixture must cross the rehash threshold",
    )
    var vals = List[String]()
    for i in range(N):
        vals.append("c" + String(i))
    var hashes = List[Int64](length=N, fill=Int64(0))
    var e = _encode(_string_batch(vals), hashes^)
    assert_equal(len(e.rev_starts), N, "every value keeps its own id")
    _assert_round_trips(e, vals, "rehash under one chain")


# =============================================================================
# §4 — the sizing helpers say what the comments claim
# =============================================================================


def test_initial_cap_is_a_power_of_two_at_or_above_the_floor() raises:
    assert_equal(_strenc_ht_initial_cap(0), 1024, "floor at 0 rows")
    assert_equal(_strenc_ht_initial_cap(1024), 1024, "floor at the floor")
    assert_equal(_strenc_ht_initial_cap(1025), 2048, "next power of two")
    assert_equal(_strenc_ht_initial_cap(70_000), 131_072, "70k rows")
    assert_equal(
        _strenc_ht_initial_cap(1 << 30),
        1 << 24,
        "the up-front allocation is clamped; growth takes it from there",
    )


def test_load_limit_is_three_quarters() raises:
    assert_equal(_strenc_ht_limit(1024), 768, "0.75 of 1024")
    assert_equal(_strenc_ht_limit(1 << 20), 786_432, "0.75 of 1M")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
